#!/bin/sh
# B0 本地判定：编译探针、跑静态/动态两份、抓 glibc/ld.so 的解码证据。
# 只读输入（probe.c），只写 B0_OUTPUT，不动任何锁定文件。
set -eu

OUT=${B0_OUTPUT:-/b0/out}
SRC=${B0_SOURCE:-/b0}
mkdir -p "$OUT"
rm -f "$OUT"/*.out "$OUT"/*.exit
REPORT="$OUT/b0-local.txt"

echo "== B0 local =="
date -u
uname -a

# 1) 运行方式：容器自身架构决定要不要 qemu。（arm64 镜像里 gcc-13-aarch64-linux-gnu
#    就是本机原生编译器，不能靠"有没有交叉命令"判断。）
MACH=$(uname -m)
if [ "$MACH" = aarch64 ] || [ "$MACH" = arm64 ]; then
  MODE=arm64-native
  QEMU_RAW=""
  QEMU_RUN=""
else
  MODE=cross-pinned
  QEMU_RAW=qemu-aarch64-static
  QEMU_RUN="qemu-aarch64-static -L /usr/aarch64-linux-gnu"
fi
if command -v aarch64-linux-gnu-gcc-13 >/dev/null 2>&1; then
  CC=aarch64-linux-gnu-gcc-13
else
  CC=gcc
fi
echo "MODE=$MODE MACH=$MACH"
echo "CC=$CC"
"$CC" --version | head -1
if [ -n "$QEMU_RAW" ]; then "$QEMU_RAW" --version | head -1; fi

echo "-- packages --"
dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null \
  | grep -E '^(libc6|libc6-dev|libc6-arm64-cross|libc6-dev-arm64-cross|gcc|gcc-13-aarch64-linux-gnu|binutils-aarch64-linux-gnu|qemu-user-static)\s' \
  | sort || true

# 2) 定位 guest 侧 glibc / 动态链接器（交叉编译器用 -print-file-name 解析，别猜路径）
DIR=""
SYSROOT=$("$CC" -print-sysroot 2>/dev/null || true)
for cand in "$("$CC" -print-file-name=libc.so.6 2>/dev/null || true)" \
            "$("$CC" -print-file-name=ld-linux-aarch64.so.1 2>/dev/null || true)"; do
  [ -n "$cand" ] || continue
  d=$(dirname "$cand")
  if [ -f "$d/libc.so.6" ] && [ -f "$d/ld-linux-aarch64.so.1" ]; then
    DIR=$d
    break
  fi
done
if [ -z "$DIR" ]; then
  for d in /usr/aarch64-linux-gnu/lib "$SYSROOT/lib" "$SYSROOT/lib/aarch64-linux-gnu" \
           /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu; do
    if [ -f "$d/libc.so.6" ] && [ -f "$d/ld-linux-aarch64.so.1" ]; then
      DIR=$d
      break
    fi
  done
fi
if [ -z "$DIR" ]; then
  echo "B0_GLIBC_DIR_NOT_FOUND sysroot=$SYSROOT"
  exit 3
fi
DIR=$(realpath "$DIR")
echo "GLIBC_DIR=$DIR"
STRINGS=$("$CC" -print-prog-name=strings 2>/dev/null || echo strings)
OBJDUMP=$("$CC" -print-prog-name=objdump 2>/dev/null || echo objdump)
READELF=$("$CC" -print-prog-name=readelf 2>/dev/null || echo readelf)
"$STRINGS" "$DIR/libc.so.6" | grep -m1 'GNU C Library' || true

# 3) 编译（动态 + 静态）
"$CC" -O0 -o "$OUT/probe.dyn" "$SRC/probe.c"
"$CC" -O0 -static -o "$OUT/probe.static" "$SRC/probe.c"
ls -l "$OUT/probe.dyn" "$OUT/probe.static"
echo "-- probe.dyn interpreter --"
readelf_line=$("$READELF" -l "$OUT/probe.dyn" | awk '/interpreter/ {print $NF}') || true
echo "interp=$readelf_line"

# 4) 运行。断言走 abort()：exit=134/139，最后一行 B0_STAGE 就是故障点。
run() {
  label=$1
  shift
  code=0
  "$@" > "$OUT/$label.out" 2>&1 || code=$?
  echo "$code" > "$OUT/$label.exit"
  echo "RUN $label exit=$code"
  sed 's/^/    /' "$OUT/$label.out" || true
}

if [ -n "$QEMU_RAW" ]; then
  run probe-static "$QEMU_RAW" "$OUT/probe.static"
  run probe-dyn-via-qemu $QEMU_RUN "$OUT/probe.dyn"
else
  run probe-static "$OUT/probe.static"
  run probe-dyn "$OUT/probe.dyn"
fi

# 5) 静态证据：断言字符串是否存在；保守常量 5120 是否编译进去（带上下文，避免数字巧合）。
echo "-- libc 断言证据（存在即证明这是 glibc 内部 assert）--"
for s in 'Fatal glibc error' 'sysconf-sigstksz' 'minsigstacksize'; do
  printf 'libc.so.6 %-18s count=%s\n' "$s" "$("$STRINGS" "$DIR/libc.so.6" | grep -c "$s" || true)"
done
echo "-- 保守常量 MINSIGSTKSZ=5120 的立即数 (#0x1400) 及其上下文 --"
for f in "$DIR/ld-linux-aarch64.so.1" "$DIR/libc.so.6" "$OUT/probe.static"; do
  printf '== %s ==\n' "$f"
  "$OBJDUMP" -d "$f" 2>/dev/null | grep -B3 -A3 '#0x1400' | head -40 || true
done

# 6) 机器可读摘要
{
  echo "MODE=$MODE"
  echo "MACH=$MACH"
  echo "CC=$("$CC" --version | head -1)"
  echo "GLIBC=$("$STRINGS" "$DIR/libc.so.6" | grep -m1 -o 'GNU C Library.*' || echo unknown)"
  echo "AX_AT_MINSIGSTKSZ=$(cat "$OUT"/probe-*.out | sed -n 's/.*AT_MINSIGSTKSZ=\([0-9]*\).*/\1/p' | head -1)"
  echo "SC_MINSIGSTKSZ=$(cat "$OUT"/probe-*.out | sed -n 's/.*B0_STAGE=MINSIGSTKSZ value=\(-\{0,1\}[0-9]*\).*/\1/p' | head -1)"
  echo "SC_SIGSTKSZ=$(cat "$OUT"/probe-*.out | sed -n 's/.*B0_STAGE=SIGSTKSZ value=\(-\{0,1\}[0-9]*\).*/\1/p' | head -1)"
  echo "ASSERT_SEEN=$(cat "$OUT"/probe-*.out | grep -c 'sysconf_sigstksz' || true)"
  echo "STATIC_EXIT=$(cat "$OUT/probe-static.exit" 2>/dev/null || echo unknown)"
  echo "DYN_EXIT=$(cat "$OUT"/probe-dyn*.exit 2>/dev/null | head -1 || echo unknown)"
} > "$REPORT" 2>/dev/null || true

echo "B0_LOCAL_DONE mode=$MODE"
cat "$REPORT"
