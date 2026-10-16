# issue #148 · 内核 4.14.186 真机判定与 build173 源码可构建性问题

本页记录一次**真机取证**：在 Redmi Note 9 5G（Android 12 / 内核 `4.14.186-perf-00243-g9a0d96109bda`）
上复现 issue #148 的失败、找出归因、并验证 build173 源码的修复。所有结论都来自实际设备输出，
不是从源码推断。

## 结论摘要

1. **issue #148 的 auxv 归因不成立**：内核不提供 `AT_MINSIGSTKSZ` 时，stock glibc 2.39 在**四种**
   配置下都不触发 `sysconf-sigstksz.h:25 assert (minsigstacksize != 0)`（见 §1 矩阵）。
2. **真机崩溃属于 proroot 自己的 guest 引导路径**：同一台机、同一份 rootfs、同一个探针，
   proroot 两模式 `exit=139`，而 proot `exit=0`。proroot 自 build172 起已从生产路径退休。
3. **本仓库提交的 `libdsha-session.so` 是陈旧的**（源码 2026-10-15 改过、二进制停在 2026-10-04），
   沿用仓库二进制会得到"出生握手/退出确认失效"的包。`tools/native-session/build.py --check`
   一条命令即可检出（见 §3.1）。本提交已按 HEAD 源码重建。
4. **维护试运行对系统 WebView 有隐性下限**：WebView 99 的设备会卡在
   `TRIAL_TIMEOUT:RENDERING`（300 s），而冷安装、引擎选择、存储/会话检查均已通过（见 §3.2）。
5. 单台设备实机验证：**修好会话桥 + 升级 WebView 后，build173 源码 + bxroot 引擎在 4.14.186 上跑通**
   （进程链 `com.dsh.client → libdsha-session.so → libbxroot.so → libbxroot-ulx.so`）。

> 本文的判定工具是 `tools/bxroot-probe/`（两个 Docker 镜像 + 探针 + 脚本）。设备原始日志、截图与
> 报告属于本机取证材料，按仓库约定不进仓库（见 §5）。

## 1. B0 判定：`AT_MINSIGSTKSZ` 缺失会不会让 glibc 断言

探针 `tools/bxroot-probe/probe.c` 依次打印 `getauxval(AT_MINSIGSTKSZ)`、
`sysconf(_SC_MINSIGSTKSZ)`、`sysconf(_SC_SIGSTKSZ)`，每步 flush —— 断言是 `abort()`，
因此最后打印出来的一行就是故障点。

| 配置 | `AT_MINSIGSTKSZ` | `_SC_MINSIGSTKSZ` | `_SC_SIGSTKSZ` | 断言 |
|---|---|---|---|---|
| 本机 Docker（arm64，glibc 2.39）静态 | `0`（缺失） | `5120` | `20480` | 无 |
| 本机 Docker 动态 + 真实 ld.so | `0` | `5120` | `20480` | 无 |
| **真机 4.14.186** 静态（adb 直跑） | `0` | `5120` | `20480` | 无 |
| **真机 4.14.186** 动态 + guest ld.so | `0` | `5120` | `20480` | 无 |
| **真机 4.14.186** guest 内过 bxroot 引擎 | `0` | `5120` | `20480` | **无** |
| 真机 4.14.186 guest 内显式 guest ld.so | `0` | `5120` | `20480` | 无 |
| 真机 build170 **proroot（历史）** | — | — | — | **有**（`exit=139`） |

机制（glibc 2.39 源码 + 设备反汇编一致）：

- `sysdeps/unix/sysv/linux/dl-parse_auxv.h` 在拷贝 auxv **之前**预置
  `auxv_values[AT_MINSIGSTKSZ] = CONSTANT_MINSIGSTKSZ`；aarch64 上该常量 = `5120`
  （`sysdeps/unix/sysv/linux/aarch64/bits/sigstack.h`）。内核给了值才覆盖。
- 静态 libc 另有 `size_t _dl_minsigstacksize = CONSTANT_MINSIGSTKSZ;`（`elf/dl-support.c`）。
- 因此值不可能为 0。设备上反汇编 `libc.so.6` 可见 `_SC_SIGSTKSZ` 分支读取
  `_rtld_global_ro._dl_minsigstacksize` 后 `cbz → assert`，再 clamp 到 5120 并 `×4`。
- 值要为 0，只能是**该进程的 ld.so 从未跑过 `_dl_parse_auxv`** —— 即引导 guest 的 loader
  自己接管了装载、跳过了 ld.so 初始化。

结论：`AT_MINSIGSTKSZ` 缺失不是崩溃原因；proroot 自己的 guest 引导才是。issue #148 的
"内核不提供 auxv ⇒ 值 0 ⇒ 断言"归因在真机上被证伪（该设备与 issue 报告的 OnePlus 7 Pro
属于同一类 4.14 内核）。

注：`AT_MINSIGSTKSZ` 在 arm64 上是较新内核才导出的 auxv 项（x86 为 5.14 引入，arm64 更晚），
4.14 没有它属正常；厂商 backport 的 ROM 会有（对照机 5.4.289-qgki 有）。

## 2. 真机链路：四次尝试的因果

同一台机、同一份包（build173 源码 + 自建签名，先卸载 build170），四次观察构成完整因果链：

| # | 现象 | 根因 | 处置与结果 |
|---|---|---|---|
| 1 | `java.lang.IllegalStateException: RUNTIME_CAPABILITY_UNCONFIRMED`；能力探针收据 `launcherExited=false`、`ownedTreeEmpty=false` | 仓库里的 `libdsha-session.so` 陈旧（§3.1） | 按 HEAD 源码 + 锁定 NDK 重建 → 探针 `outcome=READY`、`commandExit=0`、`kill-on-exit 完成` |
| 2 | 包工具探针 `DSHA_BXROOT_UNSUPPORTED: static exec unsupported`（`/usr/sbin/ldconfig.real` 是静态 ELF） | bxroot 按设计拒绝进程内执行静态 ELF | 触发 `RUNTIME_CAPABILITY_FALLBACK bxroot -> proot: confirmed isolated capability failure`（**只回退一次**），proot 完成冷安装并**提交成功** |
| 3 | 试运行 `TRIAL_TIMEOUT:RENDERING`（3 次一致，300 s 用尽） | 试运行要求完整前端在渲染器里启动 + `/api/remote.mux` 报 ready；本机 WebView 停在 2022 年的 99.0.4844.88 | 手机升级 WebView 到 `156.0.8078.25` → 试运行通过，进入界面 |
| 4 | 失败后环境未被子覆盖 | 设计行为 | `runtimeOperations` 两条事务 `RECORDED_ROLLED_BACK`（`finalized=MISSING`、`rolled-back=VALID_RECORDED`） |

第 3 项在 proot 与 bxroot 下都复现；bxroot 侧的 native 阶段明显更快（`storage` 5.9 s vs 22.5 s），
两者都会打印 `dsh web: http://127.0.0.1:<port>/?token=***`，即 guest 侧 Web 已就绪。
本机唯一的 WebView 包是 `com.google.android.webview 99.0.4844.88`，无更新版本可选。

## 3. 两条可复现的仓库级问题

### 3.1 提交的原生会话桥与源码不一致

```
git log -1 --format='%h %ci' -- tools/native-session/session-launcher.c   → 2026-10-15（build173 源码同步）
git log -1 --format='%h %ci' -- app/src/main/jniLibs/arm64-v8a/libdsha-session.so → 2026-10-04（build157 时代）
```

用锁定 NDK 重建比对：

```bash
python3 -B tools/native-session/build.py --check --ndk <ANDROID_SDK>/ndk/26.3.11579264
# → ValueError: NATIVE_SESSION_REBUILD_MISMATCH
```

三个摘要并不同：

| 来源 | `libdsha-session.so` SHA-256 | 大小 |
|---|---|---|
| 仓库提交（build157 时代） | `12ace2a08056105a663f0ebc492e568d8322a6b252550a16bc05668ed9a58ed5` | 7,392 B |
| 官方 build173 描述符记录的启动器条目 | `6a143192a8637818…` | — |
| 按 HEAD 源码 + 锁定 NDK 重建（本提交） | `5a2a6e61f8849a4c4cbd5ecbe5a9036c4039f9abde0948cd94ef37e136d7ebee` | 13,816 B |

影响：该组件负责出生握手、会话登记与退出确认。真机上表现为能力探针
`outcome=UNCONFIRMED`、`launcherExited=false`、`ownedTreeEmpty=false`，冷安装无法推进。
build173 文档要求"打包前必须按当前锁文件重新生成 / 恢复并完整核对，包括 bxroot、
**原生会话桥**、Ubuntu、DSH 和独立应急资产"；本次源码同步未带 native 二进制，
而 bxroot 因不在仓库里才被重建，会话桥被漏掉。

本提交处置：按 HEAD 源码重建会话桥（`5a2a6e61…`），并在描述符中**只**更新该启动器条目 +
重算 `runtimeId`；离线归档摘要保持官方记录。`tools/native-session/README.md` 记录该门禁。

> 注意：`6a143192…`（官方 build173 的二进制）与按 HEAD 源码重建的 `5a2a6e61…` 不同，
> 说明官方构建所用的 `session-launcher.c` 与仓库中的版本也不完全一致；官方机器重建时
> 应以 `--check` 为准重新生成并核对。

### 3.2 维护试运行对系统 WebView 有隐性下限

`app/src/main/assets/runtime-trial-page.js` 在**渲染器**里执行，只有同时满足三件事才 POST
`renderer=true`：

1. 页面引导完成（`#root` 有子节点，或收到 `dsha-startup` 的 `ready`）；
2. 被包住的 `WebSocket` 成功连到 `/api/remote.mux`；
3. 收到 `type=item` 且 `value.type=ready`、`value.host.home === 期望 HOME` 的帧。

`TrialWaitBudget.Phase.RENDERING` = **300 s**。WebView 99 的设备在这 300 s 内始终等不到
`renderer=true`（HTTP 侧 `status` 轮询一直正常，否则会报 `TRIAL_GENERATION_MISMATCH`），
于是 `TRIAL_TIMEOUT:RENDERING`、试运行判失败、环境不提交。冷安装、引擎选择、存储/会话
读写检查此时都已通过。

建议：文档明确"维护试运行需要较新的系统 WebView；不满足时使用 Low 兼容版（内置 GeckoView 143）"，
或让试运行在过旧 WebView 上以更明确的错误码提示"请升级 WebView"。

## 4. bxroot 在 4.14.186 上的表现（修好会话桥之后）

- 能力探针：多次 `outcome=READY`、`supported=true`、`commandExit=0`、`failures=[]`，
  guest 输出 `DSHA_ENGINE_CAPABILITY_READY`，收尾 `kill-on-exit 完成：遍历 12 条，结束 0，跳过 12，失败 0`。
- 试运行 Node 侧：`pnpm 248 ms → modules 567 → loader 725 → builtin-0..8 → flock → native-ready 1256
  → storage 5877 → session 6100 → plugin-ready 6171`，随后 `dsh web` 启动。
- 包工具探针：静态 `ldconfig.real` 被按设计拒绝 → 一次 proot 回退（政策允许）。
- 进程链：`com.dsh.client → libdsha-session.so → libbxroot.so → libbxroot-ulx.so`。

即：**bxroot 在这台 4.14 设备上可用**；先前 bxroot 的失败是会话桥陈旧导致的，不是引擎本身。

## 5. 未验范围

- 只做了 **Standard** 版；**Low 兼容版（GeckoView 143）未验证**。
- issue 报告那台 OnePlus 7 Pro（proot 30 s 零输出超时）**未复验**；本机 proot 一次通过，
  两台设备不是同一个第二故障。
- 本机包用自建密钥签名（非 E7E3），`runtimeId` 与官方交付不同，`dsh-runtime.bin` 为本机
  npm 重建 —— **本文的产物不是正式交付包**，也不声称复现官方 runtimeId。
- 设备侧只做非破坏性观察，未做完整机型矩阵；`libtermux.so` 与其源码同属 2026-10-07 同一次
  提交，其 builder 仅提供 Windows 路径，**本轮未重新核验**。
- 设备原始日志与报告属于本机取证材料，不随源码提交。

## 6. 复现命令

```bash
# 1) 重建并复检原生会话桥（需要 NDK 26.3.11579264）
python3 -B tools/native-session/build.py --output app/src/main/jniLibs/arm64-v8a/libdsha-session.so \
        --ndk <ANDROID_SDK>/ndk/26.3.11579264
python3 -B tools/native-session/build.py --check --ndk <ANDROID_SDK>/ndk/26.3.11579264

# 2) 重建 bxroot 闭包并核验（与 tools/bxroot/lock.json 逐字节一致）
python3 -B tools/bxroot/build.py --prepare-source <空目录>
cd <空目录> && BXROOT_OUTPUT=<输出目录> sh <repo>/tools/bxroot/build-linux.sh
python3 -B tools/bxroot/build.py --check

# 3) 描述符/启动器一致性
python3 -B tools/verify-runtime-descriptor-source.py
python3 -B tools/test-runtime-descriptor-inputs.py

# 4) B0 判定（本机 Docker，两条命令；详见 tools/bxroot-probe/README.md）
docker build -q --target b0-arm64-native --platform=linux/arm64 -t dsha-b0-arm64 tools/bxroot-probe
docker run --rm --platform=linux/arm64 -v "$PWD/artifacts/b0-auxv/arm64-native:/b0/out" dsha-b0-arm64
```
