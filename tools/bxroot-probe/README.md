# B0：`sysconf(_SC_SIGSTKSZ)` 行为判定（issue #148 取证）

判定 issue #148 的归因是否成立：**内核不提供 `AT_MINSIGSTKSZ(51)` 时，glibc 2.39 的
`sysconf(_SC_SIGSTKSZ)` 会不会触发内部断言**
`sysconf-sigstksz.h:25 assert (minsigstacksize != 0)`。

本目录只做取证，**不参与生产构建**：不写 `tools/bxroot/` 的任何锁定文件，不产出 APK，
二进制与日志落在 gitignored 的 `artifacts/b0-auxv/`。

## 结论（2026-10-16 本地实测，已完成）

在 **`AT_MINSIGSTKSZ=0`（缺失，与 issue 那台 4.14 机一致）** 的条件下，
Ubuntu 24.04 arm64 / glibc 2.39 的静态与动态程序**都不断言**：

| 观测 | 值 |
|---|---|
| `getauxval(AT_MINSIGSTKSZ)` | `0`（`errno=2`，未提供） |
| `sysconf(_SC_MINSIGSTKSZ)` | `5120`（= aarch64 `MINSIGSTKSZ`） |
| `sysconf(_SC_SIGSTKSZ)` | `20480`（= `max(5120*4, SIGSTKSZ=16384)`） |
| 断言 | 未出现（`ASSERT_SEEN=0`，exit=0） |

两条独立工具链给出完全相同结果：

- `b0-arm64-native`：容器内 glibc `2.39-0ubuntu8.9`，容器自身 aarch64；
- `b0-cross-pinned`：amd64 + `gcc-13-aarch64-linux-gnu 13.3.0-6ubuntu2~24.04.1cross1`、
  `binutils 2.42-4ubuntu2.10`、`libc6-arm64-cross 2.39-0ubuntu8cross1`、
  `qemu-user-static 1:8.2.2+ds-0ubuntu1.18`（与 `tools/bxroot/lock.json` 记录一致）。

反汇编同时给出机制证据（`libc.so.6`）：

```
ldr x0, [x0, #3728]        ; _rtld_global_ro
ldr x0, [x0, #32]          ; ._dl_minsigstacksize  ← 值来自 ld.so
cbz x0, <assert fail>      ; assert (minsigstacksize != 0)
mov x1, #0x1400            ; 5120 = MINSIGSTKSZ 保守常量
cmp x0, x1 ; csel x0, x0, x1, ge
lsl x0, x0, #2             ; *4
```

即：断言在 libc；值取自 ld.so 的 `_rtld_global_ro`；保守常量 5120 已编译进去
（`ld-linux-aarch64.so.1` 里也有把 5120 预置进 auxv 表的那条 `mov x2, #0x1400`）。

**因此 issue 里"内核不给 AT_MINSIGSTKSZ ⇒ 值 0 ⇒ 断言"的归因不成立。**
值变成 0 只可能来自"ld.so 的 `_dl_parse_auxv` 从未跑过"的启动路径，也就是引
擎自己的加载器（proroot 已被 build172 退休，bxroot 自身运行时是静态链接、按构造免疫）。
真机段用于确认这一点。

## 运行

```bash
# 与打包 rootfs 同族 glibc（arm64 原生，经 Docker Desktop binfmt）
docker build -q --target b0-arm64-native --platform=linux/arm64 -t dsha-b0-arm64 tools/bxroot-probe
docker run --rm --platform=linux/arm64 -v "$PWD/artifacts/b0-auxv/arm64-native:/b0/out" dsha-b0-arm64

# 锁定交叉工具链 + qemu-user-static（同时预演方案 B 的工具链）
docker build -q --target b0-cross-pinned -t dsha-b0-cross tools/bxroot-probe
docker run --rm -v "$PWD/artifacts/b0-auxv/cross-pinned:/b0/out" dsha-b0-cross
```

产出：`b0-local.txt`（机器可读摘要）、`probe-*.out` / `probe-*.exit`（原始输出与退出码），
以及给真机用的 `probe.static` / `probe.dyn`。

## 判定表

| `AT_MINSIGSTKSZ` | `_SC_SIGSTKSZ` | 断言 | 解释 |
|---|---|---|---|
| `0` | `20480` | 无 | **已验证**：缺失 auxv 不会让 stock glibc 断言，issue 归因不成立 |
| `0` | — | 出现 | 读源码的结论有误 → 转为"在 rootfs glibc 的调用点合成保守值"路线 |
| `5120` | `20480` | 无 | 本环境无法模拟缺失（加载器自己补了值），需另找缺失环境 |

## B0 真机段结果（2026-10-16，已完成）

设备：小米 M2007J22C（Redmi Note 9 5G）· Android 12 · 内核 **4.14.186-perf-00243-g9a0d96109bda**
装机版本：**build170 标准版**（`0.2.21-20261009.0750-dsh0.2.0-rc.2`，即 proroot 时代）。

| # | 观测 | 结果 | 证据 |
|---|---|---|---|
| 1 | 内核 auxv 是否有 51 | **无**（与 issue 同条件） | `od -An -tu8 -w16 /proc/self/auxv` |
| 2 | 缺 51 时静态 glibc | `MINSIGSTKSZ=5120` / `SIGSTKSZ=20480`，**无断言**，exit 0 | adb 直跑 `probe.static`（不经应用） |
| 3 | 缺 51 时动态 glibc + 真实 ld.so | 同上，**无断言**，exit 0 | 把交叉镜像的 `ld-linux-aarch64.so.1`+`libc.so.6` 推到设备直跑 `probe.dyn` |
| 4 | 引擎路径（应用冷安装探针） | PROROOT 与 PROROOT_DYNAMIC 均 `exit=139` + 同一条 glibc 断言；**同一 rootfs 的 PROOT `exit=0`**（`DSHA_COLD_RUNTIME_READY`/`DSHA_UBUNTU_TOOLS_READY`，输出 50 字节） | 应用导出 `DSHA-diagnostic-20261016-105037.txt` |
| 5 | 该设备真正的阻塞点 | 冷安装**已提交**；卡在**受管运行时试运行**：proot 下 `dsh web` 已起来（`http://127.0.0.1:37211/?token=***`），但 `pidRecord=MISSING`/`identityRecord=MISSING` → `error=IO_FAILURE`、`exitCode=running-or-not-started` → 试运行判失败 → 受限模式「环境需要恢复」 | 同上 |
| 6 | **guest 内过引擎（build173/bxroot）** | `AT_MINSIGSTKSZ=0` → `MINSIGSTKSZ=5120`、`SIGSTKSZ=20480`，**无断言**，exit 0 | `artifacts/b0-auxv/device/b0-probe.log`（`tools/bxroot-probe/device-run2.sh`） |
| 7 | guest 内显式用 guest 自己的 ld.so（对照） | 同上，exit 0 | 同上 |
| 8 | guest 内静态探针（bxroot） | `DSHA_BXROOT_UNSUPPORTED: static exec unsupported`、exit 126 —— **bxroot 的设计限制**（拒绝静态 ELF 进程内执行），与 `ldconfig.real` 同源 | 同上 |

### B0 最终矩阵（四格 + 历史对照）

| 配置 | `AT_MINSIGSTKSZ` | `sysconf(_SC_SIGSTKSZ)` | 是否断言 |
|---|---|---|---|
| 宿主机 4.14.186，静态 glibc 2.39（adb 直跑） | `0`（缺失） | `20480` | 否 |
| 宿主机，动态 + guest ld.so（adb 直跑） | `0` | `20480` | 否 |
| **guest 内过 bxroot 引擎（build173）** | `0` | `20480` | **否** |
| guest 内显式 guest ld.so（对照） | `0` | `20480` | 否 |
| **build170 真机 proroot（历史）** | — | — | **是（exit=139 + `sysconf-sigstksz.h:25` 断言）** |

**结论**：`AT_MINSIGSTKSZ` 缺失**不会**让 stock glibc 2.39 断言（四种配置一致）。
issue #148 的 auxv 归因在真机上被证伪；崩溃属于 **proroot 自己的 guest 引导路径**（它会用自己的
loader 装载 guest、跳过 ld.so 的 `_dl_parse_auxv`，使 `_rtld_global_ro._dl_minsigstacksize` 保持 0），
而 proot / bxroot 都让 guest 的真实 ld.so 完成初始化，因此都正常。proroot 已从 build172 起从生产路径退休。

结论升级：

- 第 2、3 条把 issue 的 auxv 归因**在真机上证伪**：同一内核缺 51，stock glibc 2.39 的静态与
  动态（真实 `ld.so`）两条路径都不断言。
- 第 4 条把断言**定位到 proroot 自己的 loader 引导路径**：同一台机、同一份 rootfs、同一个探针，
  换成 proot（让 guest 自己的 `ld.so` 跑 `_dl_parse_auxv`）即 `exit=0`，约 1 秒完成。
  内核、glibc、打包 rootfs 三者都被排除。
- 第 5 条是 issue 里没有的事实：这台设备上 proroot 断言**并不是阻塞点**（proot 顶得住），
  真正卡住的是 build170 的试运行身份/pid 记录缺失 —— 对应 build171 记录的
  「复用签名 native-session 出生握手，在 guest 前记录本次独立会话」。
- 注意 issue 里那位 OnePlus 7 Pro 用户 proot 30 秒零输出超时，本机 proot 一次通过；
  两台设备不是同一个第二故障。

证据文件（`artifacts/b0-auxv/device/`）：`DSHA-diagnostic.txt`（应用导出，含 proroot 两模式原始输出、
寄存器转储与试运行记录）、`DSHA-error-log.txt`、`DSHA-error-log-1050.txt`、
`logcat-crash.txt`（无 `Fatal signal`/tombstone 记录）、`screen1.png`。

## 真机段操作步骤（可复用）

准备：一台 **内核 4.14.x** 的 arm64 机（如 issue 的 OnePlus 7 Pro / Redmi Note 9 5G）。
若要用 `probe.dyn` 验证"引擎路径"，需要 guest 已就绪（终端的入口受环境门禁限制）；
在环境未就绪的机器上，改用应用自身导出的诊断报告即可拿到引擎的原始输出。

```bash
# 1) 推送两份探针（应用把 /storage/emulated/0 绑定到 guest 的 /sdcard）
adb push artifacts/b0-auxv/arm64-native/probe.static /sdcard/Download/
adb push artifacts/b0-auxv/arm64-native/probe.dyn    /sdcard/Download/
adb push tools/bxroot-probe/device-run.sh           /sdcard/Download/

# 2) 在 DSHA 的 guest 终端里执行（不需要 root）
sh /sdcard/Download/device-run.sh
```

观察点：

- `AUXV51_VALUE` 缺失/为 0 → 与 issue 环境一致；出现了，说明该 ROM backport 了这项。
- 第 4 步 `probe.dyn` 过引擎：若打印 `B0_STAGE=AUXV` 后**在 `MINSIGSTKSZ` 前被打死**
  （exit 134/139 + `Fatal glibc error`）→ 引擎的 boot 路径确实跳过了 ld.so 初始化，
  方案 B 的 auxv/loader 修法成立；若正常打到 `B0_STAGE=DONE` → proroot 时代的断言
  随引擎迁移消失，可直接按新归因关 issue。
- 第 5、6 步是静态与"显式真 ld.so"对照，用来区分"guest glibc 问题"与"引擎 loader 问题"。

## 边界

- 本目录不产出 APK、不改 `tools/bxroot/lock.json`、不改 rootfs 与基础环境编号 10。
- `artifacts/` 已被 gitignore，证据与二进制不进仓库；**本页结论的正式记录在
  [`docs/b0-issue148-4.14-verification.md`](../../docs/b0-issue148-4.14-verification.md)**。
- Docker Desktop 的 binfmt(qemu) 不提供 `AT_MINSIGSTKSZ`，这正好复现了"缺 51"的条件；
  但它**不能**替代真机：引擎自己的 loader 行为只有在设备上跑才能观测。
- 目录内文件按仓库规则用 LF；若纳入提交需 `python tools/check-source-hygiene.py` 通过。
