# 原生会话桥（`libdsha-session.so`）

所有有界/非交互的宿主命令都由这个原生启动器监督：它在 guest 之前登记本轮独立会话
（出生握手），并在结束时报出本轮的退出/身份回执。**它是受管运行时能力探针、冷安装探针与
受管试运行的共同前置**，一旦与源码不一致，真机会表现为
`RUNTIME_CAPABILITY_UNCONFIRMED`（`launcherExited=false`、`ownedTreeEmpty=false`）。

## 构建与核验

源码：`session-launcher.c`（唯一输入）。工具链固定为 `ci/toolchain.lock.json` 的
`ndk = 26.3.11579264`，目标 `aarch64-linux-android23`，`-Wl,-z,max-page-size=16384`。

```bash
# 写模式：显式给出输出路径
python3 -B tools/native-session/build.py --output app/src/main/jniLibs/arm64-v8a/libdsha-session.so \
        --ndk <ANDROID_SDK>/ndk/26.3.11579264

# 只读核验：在临时目录重建并逐字节比较，不改动提交的 ELF
python3 -B tools/native-session/build.py --check --ndk <ANDROID_SDK>/ndk/26.3.11579264
# 通过时打印：PASS native session reproducible bytes <sha256>
```

## 打包前必须做的一步

**提交的 ELF 与 `session-launcher.c` 不一致时，构建出的包在真机上无法通过能力探针。**
历史上发生过一次（源码 2026-10-15 修改、提交的 ELF 仍是 2026-10-04 的字节），
详见 [issue #148 判定记录](../../docs/b0-issue148-4.14-verification.md) §3.1。

因此：**改过 `session-launcher.c`、或从源码检出恢复 native 二进制之后，必须运行
`--check` 并把重建结果提交**，与 `tools/bxroot/build.py --check`、
`tools/prepare-bxroot-native-proof.py --check` 同等对待。

## 与其它门禁的关系

- `tools/bxroot/build.py --check` 只覆盖 bxroot 闭包与 `preservedProot`，**不覆盖本组件**。
- 本组件的摘要出现在生成的 `app/src/main/assets/runtime-descriptor.json` 的 `launcherInputs` 中，
  由 `tools/verify-runtime-descriptor-source.py` 逐字节核验（`checkedLaunchers`）。
  重建之后必须重新生成描述符（`tools/prepare-runtime-descriptor.py --write`），
  否则该门禁会报 `DESCRIPTOR_LAUNCHER_BYTES`。
