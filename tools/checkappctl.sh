#!/bin/bash
#
# checkappctl.sh — 用 PATH 桩验证 estudioctl.sh，不需要 root、不碰真实系统
#
#   ./tools/checkappctl.sh [estudioctl.sh 路径]
#
set -u

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CTL=${1:-$ROOT_DIR/scripts/estudioctl.sh}
[ -x "$CTL" ] || { echo "FAIL: 找不到可执行的 ctl：$CTL"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/estudio-ctl.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/log"
mkdir -p "$BIN"
: > "$LOG"
export ESTUDIO_LOG="$LOG"

# 通用桩：把 "名字 参数..." 追加进 $ESTUDIO_LOG，退出 0
make_stub() {
    cat > "$BIN/$1" <<EOF
#!/bin/bash
{
  printf '%s' "$1"
  printf ' %s' "\$@"
  printf '\n'
  for a in "\$@"; do printf '%s\n' "\$a"; done
} >> "\$ESTUDIO_LOG"
exit 0
EOF
    chmod +x "$BIN/$1"
}

for c in lpadmin lp lpstat launchctl chown chmod; do make_stub "$c"; done

# id -u 必须返回 0，让 need_root 通过
cat > "$BIN/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then echo 0; exit 0; fi
/usr/bin/id "$@"
EOF
chmod +x "$BIN/id"

# lpstat 桩：输出一个本驱动队列和一个无关队列
cat > "$BIN/lpstat" <<'EOF'
#!/bin/bash
printf 'device for eSTUDIO2823AM: socket://10.0.0.5:9100\n'
printf 'device for OtherPrinter: ipp://x/y\n'
EOF
chmod +x "$BIN/lpstat"

PATH="$BIN:${PATH:-/usr/bin:/bin}"
export PATH

FILTER_DIR="$TMP/filter"
PPD_DIR="$TMP/ppds"
CUPS_PPD_DIR="$TMP/cupsppd"
mkdir -p "$FILTER_DIR" "$PPD_DIR" "$CUPS_PPD_DIR"
export ESTUDIO_FILTER_DIR="$FILTER_DIR" \
       ESTUDIO_PPD_DIR="$PPD_DIR" \
       ESTUDIO_CUPS_PPD_DIR="$CUPS_PPD_DIR" \
       ESTUDIO_FILTER_SRC="$TMP/fake-filter" \
       ESTUDIO_PPD_SRC="$TMP/fake.ppd"
: > "$TMP/fake-filter"; : > "$TMP/fake.ppd"

fail=0
ctl() {
    local out rc
    out=$("$CTL" "$@"); rc=$?
    [ "$rc" = 0 ] || { echo "FAIL: ctl $* 退出码=$rc（期望 0）"; fail=1; }
    printf '%s\n' "$out"
}

lib() { ESTUDIO_LIB_ONLY=1 bash -c '. "$1"; shift; "$@"' _ "$CTL" "$@"; }

clear_log() { : > "$LOG"; }
has() {
    [ -s "$LOG" ] || { echo "FAIL: 日志为空，断言 '$1' 无效"; fail=1; return; }
    grep -qF -- "$1" "$LOG" || { echo "FAIL: 日志缺少: $1"; fail=1; }
}
hasnt() {
    [ -s "$LOG" ] || { echo "FAIL: 日志为空，负向断言 '$1' 无效"; fail=1; return; }
    grep -qF -- "$1" "$LOG" && { echo "FAIL: 日志不应有: $1"; fail=1; }
    return 0
}
ok()     { echo "ok   $1"; }

# --- status：未安装 / 已安装 ---
clear_log
out=$(ctl status)
[ "$out" = "not-installed" ] || { echo "FAIL: status 应为 not-installed，得到 '$out'"; fail=1; }
ok "status 未安装"

: > "$FILTER_DIR/rastertoestudio"
: > "$PPD_DIR/eSTUDIO2823AM.ppd"
out=$(ctl status)
[ "$out" = "installed" ] || { echo "FAIL: status 应为 installed，得到 '$out'"; fail=1; }
rm -f "$FILTER_DIR/rastertoestudio" "$PPD_DIR/eSTUDIO2823AM.ppd"
ok "status 已安装"

# 只装 filter / 只装 PPD 都必须报 not-installed
: > "$FILTER_DIR/rastertoestudio"
rm -f "$PPD_DIR/eSTUDIO2823AM.ppd"
out=$(ctl status)
[ "$out" = "not-installed" ] || { echo "FAIL: 仅 filter 存在时应为 not-installed，得到 '$out'"; fail=1; }
rm -f "$FILTER_DIR/rastertoestudio"

: > "$PPD_DIR/eSTUDIO2823AM.ppd"
out=$(ctl status)
[ "$out" = "not-installed" ] || { echo "FAIL: 仅 PPD 存在时应为 not-installed，得到 '$out'"; fail=1; }
rm -f "$PPD_DIR/eSTUDIO2823AM.ppd"
ok "status 单文件缺失"

# --- 纯函数：队列名校验 ---
lib valid_queue_name foo || { echo "FAIL: 应接受 foo"; fail=1; }
lib valid_queue_name ok-name_1 || { echo "FAIL: 应接受 ok-name_1"; fail=1; }
lib valid_queue_name -rf && { echo "FAIL: 不应接受 -rf"; fail=1; }
lib valid_queue_name '' && { echo "FAIL: 不应接受空名"; fail=1; }
lib valid_queue_name 'a b' && { echo "FAIL: 不应接受含空格"; fail=1; }
lib valid_queue_name a.b && { echo "FAIL: 不应接受 a.b"; fail=1; }
lib valid_queue_name "$(printf 'a%.0s' $(seq 1 127))" || { echo "FAIL: 127 字符应接受"; fail=1; }
lib valid_queue_name "$(printf 'a%.0s' $(seq 1 128))" && { echo "FAIL: 128 字符应拒绝"; fail=1; }
ok "valid_queue_name 边界"

# --- 纯函数：to_uri ---
out=$(lib to_uri 10.0.0.5) && [ "$out" = "socket://10.0.0.5:9100" ] \
    || { echo "FAIL: to_uri 裸 IP"; fail=1; }
out=$(lib to_uri printer.local) && [ "$out" = "socket://printer.local:9100" ] \
    || { echo "FAIL: to_uri 主机名"; fail=1; }
out=$(lib to_uri printer:9200) && [ "$out" = "socket://printer:9200" ] \
    || { echo "FAIL: to_uri 自定义端口"; fail=1; }
out=$(lib to_uri socket://10.0.0.5:9100) && [ "$out" = "socket://10.0.0.5:9100" ] \
    || { echo "FAIL: to_uri 完整 URI"; fail=1; }
lib to_uri ipp://h && { echo "FAIL: to_uri 应拒绝 ipp://"; fail=1; }
lib to_uri ipss://h && { echo "FAIL: to_uri 应拒绝 ipss://"; fail=1; }
lib to_uri http://h && { echo "FAIL: to_uri 应拒绝 http://"; fail=1; }
lib to_uri socket:// && { echo "FAIL: to_uri 应拒绝空主机"; fail=1; }
lib to_uri socket://:9100 && { echo "FAIL: to_uri 应拒绝空主机+端口"; fail=1; }
lib to_uri 10.0.0.5:abc && { echo "FAIL: to_uri 应拒绝非数字端口"; fail=1; }
lib to_uri 'a b' && { echo "FAIL: to_uri 应拒绝空格"; fail=1; }
lib to_uri -x && { echo "FAIL: to_uri 应拒绝 - 开头"; fail=1; }
ok "to_uri 边界"

echo "ctl 基础检查：$([ "$fail" = 0 ] && echo 全部通过 || echo 有失败)"
exit "$fail"
