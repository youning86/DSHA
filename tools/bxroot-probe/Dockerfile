# B0 判定环境的两个 target（用法与判定表见 README.md）。
#
#   b0-arm64-native  Ubuntu 24.04 arm64 原生。glibc 与打包 rootfs 同族
#                    （2.39-0ubuntu8.x），执行经 Docker Desktop 的 binfmt/qemu。
#                    用于回答"缺少 AT_MINSIGSTKSZ 时 stock glibc 会不会断言"。
#   b0-cross-pinned  amd64 + tools/bxroot/lock.json 记录的同款 aarch64 交叉工具链
#                    + qemu-user-static。用于产出现场运行所需的 aarch64 二进制，
#                    并顺带预演方案 B 要用的固定工具链。
#
# 两个 target 都不写任何锁定文件、不产出 APK。

FROM ubuntu:24.04 AS b0-arm64-native
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc libc6-dev binutils file ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /b0
COPY probe.c run-local.sh /b0/
CMD ["/bin/sh", "/b0/run-local.sh"]

FROM ubuntu:24.04 AS b0-cross-pinned
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc-13-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross \
      qemu-user-static binutils file ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /b0
COPY probe.c run-local.sh /b0/
CMD ["/bin/sh", "/b0/run-local.sh"]
