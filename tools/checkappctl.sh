#!/bin/bash
#
# checkappctl.sh — 用 PATH 桩验证 estudioctl.sh，不需要 root、不碰真实系统
#
#   ./tools/checkappctl.sh [estudioctl.sh 路径]
#
set -u

CTL=${1:-./scripts/estudioctl.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/estudio-ctl.XXXXXX")
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
printf '%s' "$1" >> "\$ESTUDIO_LOG"
printf ' %q' "\$@" >> "\$ESTUDIO_LOG"
printf '\n' >> "\$ESTUDIO_LOG"
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

PATH="$BIN:$PATH"
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
clear_log() { : > "$LOG"; }
has()    { grep -qF "$1" "$LOG" || { echo "FAIL: 日志缺少: $1"; fail=1; }; }
hasnt()  { grep -qF "$1" "$LOG" && { echo "FAIL: 日志不应有: $1"; fail=1; }; return 0; }
ok()     { echo "ok   $1"; }

# --- status：未安装 ---
clear_log
out=$("$CTL" status)
[ "$out" = "not-installed" ] || { echo "FAIL: status 应为 not-installed，得到 '$out'"; fail=1; }
[ "$fail" = 0 ] && ok "status 未安装"

echo "ctl 基础检查：$([ "$fail" = 0 ] && echo 全部通过 || echo 有失败)"
exit "$fail"
