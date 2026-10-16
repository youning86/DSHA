#!/bin/sh
# B0 真机段（修正版）：/sdcard 是 FUSE noexec，不能直接执行；
# 先把探针拷进 guest 自己的文件系统（/root），再运行。
# 用法（在 DSHA 的 guest 终端里）：
#   sh /sdcard/Android/data/com.dsh.client/files/b0/device-run2.sh
set -u

SRC=${1:-$(dirname "$0")}
LOG=${2:-/sdcard/Download/b0-probe.log}
STAGE=/root/b0
TMP="/tmp/b0.$$"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

run() {
  label=$1
  shift
  say ""
  say "-- $label --"
  code=0
  "$@" > "$TMP" 2>&1 || code=$?
  tee -a "$LOG" < "$TMP"
  say "exit=$code"
  rm -f "$TMP"
}

: > "$LOG" 2>/dev/null || LOG=/dev/null
mkdir -p "$STAGE" || exit 3

say "== B0 device (v2) =="
say "uname: $(uname -a 2>&1)"
say "引擎提示：进程链里 libbxroot* = bxroot，libproot* = proot"

say ""
say "-- 1) guest 内 /proc/self/auxv 的 AT_MINSIGSTKSZ(51) --"
run "auxv-51" sh -c 'od -An -tu8 -w16 /proc/self/auxv 2>/dev/null | awk "{for(i=1;i<=NF-1;i+=2) if(\$i==51) print \"AUXV51_VALUE=\"\$(i+1)}"; echo AUXV_SCAN_DONE'

say ""
say "-- 2) guest glibc / ld.so 身份 --"
run "ldso-version" sh -c '/lib/ld-linux-aarch64.so.1 --version 2>&1 | head -1'

say ""
say "-- 3) 拷进 guest 文件系统（/sdcard 不能执行）--"
run "stage-copy" sh -c "cp '$SRC/probe.dyn' '$STAGE/probe.dyn' && cp '$SRC/probe.static' '$STAGE/probe.static' && chmod 755 '$STAGE/probe.dyn' '$STAGE/probe.static' && ls -l '$STAGE'"

say ""
say "-- 4) probe.dyn：过引擎 + guest 真实 ld.so（B0 关键判定）--"
run "probe-dyn-via-engine" "$STAGE/probe.dyn"

say ""
say "-- 5) probe.static：静态链接（bxroot 会按设计拒绝静态 ELF，属预期）--"
run "probe-static" "$STAGE/probe.static"

say ""
say "-- 6) 显式用 guest 自己的 ld.so 启动同一份动态二进制（对照）--"
run "probe-dyn-explicit-ldso" /lib/ld-linux-aarch64.so.1 --library-path /lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu "$STAGE/probe.dyn"

say ""
say "B0_DEVICE_V2_DONE log=$LOG"
