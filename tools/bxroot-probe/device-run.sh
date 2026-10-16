#!/bin/sh
# B0 真机段：在 DSHA 的 guest 终端里运行（不需要 root）。
# 结果同时写回 $DIR/b0-device.log，可用 adb pull 取回，不必手工复制。
# 用法：把 probe.static / probe.dyn / 本脚本 放到 /sdcard/Download 后执行
#   sh /sdcard/Download/device-run.sh
# 可选参数指定目录： sh /sdcard/Download/device-run.sh /sdcard/Download
set -u

DIR=${1:-/sdcard/Download}
LOG="$DIR/b0-device.log"
TMP="/tmp/b0-device.$$"

: > "$LOG" 2>/dev/null || LOG="/dev/null"

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

say "== B0 device $(date -u 2>/dev/null) =="
say "uname: $(uname -a 2>&1)"

say ""
say "-- 1) 宿主内核 auxv 里的 AT_MINSIGSTKSZ(51) --"
run "auxv-51" sh -c 'od -An -tu8 -w16 /proc/self/auxv 2>/dev/null | awk "{for(i=1;i<=NF-1;i+=2) if(\$i==51) print \"AUXV51_VALUE=\"\$(i+1)}"; echo AUXV_SCAN_DONE'

say ""
say "-- 2) guest 侧 glibc / 动态链接器身份 --"
run "ldso-version" sh -c '/lib/ld-linux-aarch64.so.1 --version 2>&1 | head -1'
run "glibc-files" sh -c 'ls -l /lib/ld-linux-aarch64.so.1 /lib/aarch64-linux-gnu/libc.so.6 /usr/lib/aarch64-linux-gnu/libc.so.6 2>/dev/null'

say ""
say "-- 3) 探针文件 --"
run "probe-files" sh -c "ls -l '$DIR/probe.static' '$DIR/probe.dyn' 2>/dev/null || echo PROBE_FILES_MISSING"

say ""
say "-- 4) probe.dyn：走引擎 + guest 真实 ld.so（关键判定）--"
run "probe-dyn-via-engine" "$DIR/probe.dyn"

say ""
say "-- 5) probe.static：静态链接，无 loader 参与（对照）--"
run "probe-static" "$DIR/probe.static"

say ""
say "-- 6) 显式用 guest 自己的 ld.so 启动同一份动态二进制（对照）--"
run "probe-dyn-explicit-ldso" /lib/ld-linux-aarch64.so.1 --library-path /lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu "$DIR/probe.dyn"

say ""
say "B0_DEVICE_DONE log=$LOG"
