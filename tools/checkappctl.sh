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
TMP=$(cd "$TMP" && pwd)   # 归一化（TMPDIR 可能以 / 结尾，出现 // 会让路径字符串比较失效）
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

for c in lp launchctl chown chmod; do make_stub "$c"; done

# lpadmin 桩：除记录参数外，可选地记录“驱动 PPD 当时是否还在”（用于验证删除顺序）
cat > "$BIN/lpadmin" <<'EOF'
#!/bin/bash
{
  printf '%s' lpadmin
  printf ' %s' "$@"
  printf '\n'
  for a in "$@"; do printf '%s\n' "$a"; done
  if [ -n "${ESTUDIO_ORDER_FILE:-}" ]; then
    if [ -f "$ESTUDIO_ORDER_FILE" ]; then
      printf 'order: driver-present\n'
    else
      printf 'order: driver-gone\n'
    fi
  fi
} >> "$ESTUDIO_LOG"
[ "${ESTUDIO_LPADMIN_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$BIN/lpadmin"

# id -u 默认返回 0；ESTUDIO_FAKE_UID 可模拟非 root
cat > "$BIN/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then echo "${ESTUDIO_FAKE_UID:-0}"; exit 0; fi
/usr/bin/id "$@"
EOF
chmod +x "$BIN/id"

# lpstat 桩：输出一个本驱动队列和一个无关队列
#   ESTUDIO_LPSTAT_EMPTY=1 → 无任何队列（-v 返回 1，-r 正常）
#   ESTUDIO_LPSTAT_FAIL=1  → CUPS 服务不可用（-v 与 -r 都失败）
cat > "$BIN/lpstat" <<'EOF'
#!/bin/bash
[ "${ESTUDIO_LPSTAT_FAIL:-0}" = 1 ] && { echo "lpstat: error" >&2; exit 1; }
case "${1:-}" in
    -r) echo "scheduler is running"; exit 0 ;;
esac
[ "${ESTUDIO_LPSTAT_EMPTY:-0}" = 1 ] && exit 1
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
# 同 hasnt，但允许日志为空（用于“本就不该执行任何命令”的负向校验）
hasnt_any() {
    grep -qF -- "$1" "$LOG" 2>/dev/null && { echo "FAIL: 日志不应有: $1"; fail=1; }
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

# --- list：只列 PPD 指向本驱动 filter 的队列 ---
clear_log
printf '*cupsFilter: "application/vnd.cups-raster 0 rastertoestudio"\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
out=$(ctl list)
[ "$out" = "$(printf 'eSTUDIO2823AM\tsocket://10.0.0.5:9100')" ] \
    || { echo "FAIL: list 输出不符：'$out'"; fail=1; }
case "$out" in *OtherPrinter*) echo "FAIL: list 混入了无关队列"; fail=1 ;; esac
ok "list 只列本驱动队列"

# PPD 存在但不含 filter，或只是相似名字，都不应列出
clear_log
printf '*cupsFilter: "application/vnd.cups-raster 0 notrastertoestudio"\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
out=$(ctl list)
[ -z "$out" ] || { echo "FAIL: PPD 不含本驱动 filter 时不应列出：'$out'"; fail=1; }
ok "list 忽略不含本驱动 filter 的 PPD"

# 一台打印机都没有时：list 必须成功且输出为空（CUPS 的 lpstat -v 此时返回 1）
clear_log
out=$(ESTUDIO_LPSTAT_EMPTY=1 "$CTL" list); rc=$?
[ "$rc" = 0 ] || { echo "FAIL: 无队列时 list 应成功，得到 rc=$rc"; fail=1; }
[ -z "$out" ] || { echo "FAIL: 无队列时 list 应输出空，得到 '$out'"; fail=1; }
ok "list 无队列时返回空"

# CUPS 服务不可用时必须报错，且 uninstall 不得删除任何东西
clear_log
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
if ESTUDIO_LPSTAT_FAIL=1 "$CTL" list >/dev/null 2>&1; then
    echo "FAIL: CUPS 不可用时 list 应返回非 0"; fail=1
fi
clear_log
if ESTUDIO_LPSTAT_FAIL=1 "$CTL" uninstall-driver --remove-queues >/dev/null 2>&1; then
    echo "FAIL: CUPS 不可用时 uninstall-driver --remove-queues 应中止"; fail=1
fi
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] || { echo "FAIL: 中止时不应删除驱动 PPD"; fail=1; }
grep -qF "lpadmin -x" "$LOG" 2>/dev/null && { echo "FAIL: 中止时不应调用 lpadmin -x"; fail=1; }
ok "list 报告 CUPS 不可用，uninstall 不误删"

# --- install-driver：真实复制到临时目录 ---
clear_log
rm -f "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
[ -f "$FILTER_DIR/rastertoestudio" ] || { echo "FAIL: filter 未安装"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] || { echo "FAIL: PPD 未安装"; fail=1; }
has "chown root:wheel"
[ "$(ctl status)" = "installed" ] || { echo "FAIL: status 应为 installed"; fail=1; }
ok "install-driver 安装 filter+PPD，status=installed"

# 非 root 且非 dry-run 必须拒绝
clear_log
if ESTUDIO_FAKE_UID=1000 "$CTL" install-driver >/dev/null 2>&1; then
    echo "FAIL: 非 root 执行 install-driver 应失败"; fail=1
fi
ok "install-driver 拒绝非 root"

# --- dry-run：位置无关、免 root、只打印不落地 ---
clear_log
rm -f "$FILTER_DIR/rastertoestudio" "$PPD_DIR/eSTUDIO2823AM.ppd"
ESTUDIO_FAKE_UID=1000 "$CTL" install-driver --dry-run >"$TMP/dry" 2>&1 \
    || { echo "FAIL: install-driver --dry-run（非 root）应成功"; fail=1; }
grep -q "DRY:.*install -m 755" "$TMP/dry" || { echo "FAIL: dry-run 未打印 install 命令"; fail=1; }
[ -f "$FILTER_DIR/rastertoestudio" ] && { echo "FAIL: dry-run 不应安装 filter"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] && { echo "FAIL: dry-run 不应安装 PPD"; fail=1; }
[ -s "$LOG" ] && { echo "FAIL: dry-run 不应执行任何外部命令"; fail=1; }
ok "dry-run 位置无关、免 root、不落地"

# --- uninstall-driver（不带 --remove-queues）：删驱动文件，不动队列 ---
clear_log
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
clear_log
"$CTL" uninstall-driver >/dev/null || { echo "FAIL: uninstall-driver 失败"; fail=1; }
[ -f "$FILTER_DIR/rastertoestudio" ] && { echo "FAIL: filter 未删除"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] && { echo "FAIL: 驱动目录 PPD 未删除"; fail=1; }
hasnt "lpadmin -x"
[ "$(ctl status)" = "not-installed" ] || { echo "FAIL: status 应为 not-installed"; fail=1; }
ok "uninstall-driver 删驱动文件、保留队列"

# --- uninstall-driver --remove-queues：先删队列，再删驱动文件 ---
clear_log
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
ESTUDIO_ORDER_FILE="$PPD_DIR/eSTUDIO2823AM.ppd" \
    "$CTL" uninstall-driver --remove-queues >/dev/null \
    || { echo "FAIL: uninstall-driver --remove-queues 失败"; fail=1; }
has "lpadmin -x eSTUDIO2823AM"
has "order: driver-present"
hasnt "order: driver-gone"
hasnt "lpadmin -x OtherPrinter"
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] && { echo "FAIL: 驱动 PPD 未删除"; fail=1; }
ok "uninstall-driver --remove-queues 先删队列再删驱动"

# 一台队列都没有时，uninstall --remove-queues 仍应正常删驱动
clear_log
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
clear_log
ESTUDIO_LPSTAT_EMPTY=1 "$CTL" uninstall-driver --remove-queues >/dev/null \
    || { echo "FAIL: 无队列时 uninstall-driver --remove-queues 应成功"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] && { echo "FAIL: 无队列时驱动 PPD 未删除"; fail=1; }
ok "uninstall-driver 无队列时仍删驱动"

# --- add：默认补 socket:// 与 :9100 ---
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
clear_log
"$CTL" add MyPrn 10.0.0.9 >/dev/null || { echo "FAIL: add 失败"; fail=1; }
has "lpadmin -p MyPrn -E -v socket://10.0.0.9:9100"
has "-P $PPD_DIR/eSTUDIO2823AM.ppd"
has "-o printer-is-shared=false"
hasnt "lpadmin -d MyPrn"
hasnt "lp -d MyPrn"
ok "add 归一化 URI 并建队列"

# --- add --default --test ---
clear_log
"$CTL" add MyPrn 10.0.0.9 --default --test >/dev/null || { echo "FAIL: add --default --test 失败"; fail=1; }
has "lpadmin -d MyPrn"
has "lp -d MyPrn /etc/hosts"
ok "add --default --test 设置默认并发测试页"

# --- add 完整 URI 原样保留（含自定义端口）---
clear_log
"$CTL" add MyPrn "socket://host.local:9101" >/dev/null || { echo "FAIL: add 完整 URI 失败"; fail=1; }
has "lpadmin -p MyPrn -E -v socket://host.local:9101"
ok "add 接受完整 socket:// URI"

# --- add：驱动未安装时必须拒绝 ---
rm -f "$PPD_DIR/eSTUDIO2823AM.ppd"
clear_log
if "$CTL" add NoDrv 10.0.0.9 >/dev/null 2>&1; then
    echo "FAIL: 驱动未安装时 add 应失败"; fail=1
fi
hasnt_any "lpadmin -p NoDrv"
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
ok "add 拒绝未安装驱动"

# --- add / testpage 负向与非法输入 ---
for bad in "" "a b" "a/b" "a.b" "-x"; do
    clear_log
    if "$CTL" add "$bad" 10.0.0.9 >/dev/null 2>&1; then
        echo "FAIL: 非法队列名 '$bad' 应失败"; fail=1
    fi
    hasnt_any "lpadmin"
done
clear_log
if "$CTL" add GoodName "ipp://1.2.3.4" >/dev/null 2>&1; then
    echo "FAIL: 非 socket scheme 应失败"; fail=1
fi
hasnt_any "lpadmin"
clear_log
if "$CTL" add GoodName 10.0.0.9 --bogus >/dev/null 2>&1; then
    echo "FAIL: add 未知选项应失败"; fail=1
fi
hasnt_any "lpadmin"
ok "add 拒绝非法队列名/scheme/选项"

# --- testpage ---
clear_log
ESTUDIO_FAKE_UID=1000 "$CTL" testpage MyPrn >/dev/null \
    || { echo "FAIL: testpage 失败（普通用户身份也应能打测试页）"; fail=1; }
has "lp -d MyPrn /etc/hosts"
if "$CTL" testpage "bad name" >/dev/null 2>&1; then
    echo "FAIL: testpage 非法队列名应失败"; fail=1
fi
ok "testpage 发送测试页并校验队列名"

# --- add --dry-run 免 root ---
clear_log
ESTUDIO_FAKE_UID=1000 "$CTL" add DryPrn 10.0.0.9 --dry-run >"$TMP/dry" 2>&1 \
    || { echo "FAIL: add --dry-run（非 root）应成功"; fail=1; }
grep -q "DRY:.*lpadmin -p DryPrn" "$TMP/dry" || { echo "FAIL: add --dry-run 未打印命令"; fail=1; }
[ -s "$LOG" ] && { echo "FAIL: add --dry-run 不应执行外部命令"; fail=1; }
ok "add --dry-run 免 root"

# --- set-port ---
clear_log
"$CTL" set-port MyPrn 10.0.0.77 >/dev/null || { echo "FAIL: set-port 失败"; fail=1; }
has "lpadmin -p MyPrn -v socket://10.0.0.77:9100"
ok "set-port 修改端口"

clear_log
if "$CTL" set-port MyPrn "http://x" >/dev/null 2>&1; then
    echo "FAIL: set-port 非 socket scheme 应失败"; fail=1
fi
if "$CTL" set-port "bad name" 10.0.0.1 >/dev/null 2>&1; then
    echo "FAIL: set-port 非法队列名应失败"; fail=1
fi
hasnt_any "lpadmin"
ok "set-port 拒绝非法输入"

# --- remove：删队列 + 删 PPD 配置 ---
clear_log
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/MyPrn.ppd"
"$CTL" remove MyPrn >/dev/null || { echo "FAIL: remove 失败"; fail=1; }
has "lpadmin -x MyPrn"
[ -f "$CUPS_PPD_DIR/MyPrn.ppd" ] && { echo "FAIL: 队列 PPD 配置未删除"; fail=1; }
ok "remove 删队列与 PPD 配置"

# remove 幂等：lpadmin 失败也要清掉残留配置
clear_log
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/MyPrn.ppd"
ESTUDIO_LPADMIN_FAIL=1 "$CTL" remove MyPrn >/dev/null 2>&1 \
    || { echo "FAIL: remove 应当幂等（lpadmin 失败不致命）"; fail=1; }
[ -f "$CUPS_PPD_DIR/MyPrn.ppd" ] && { echo "FAIL: 残留 PPD 配置未清理"; fail=1; }
ok "remove 幂等清理残留配置"

# --- set-port / remove --dry-run 免 root ---
clear_log
ESTUDIO_FAKE_UID=1000 "$CTL" set-port MyPrn 10.0.0.1 --dry-run >"$TMP/dry" 2>&1 \
    || { echo "FAIL: set-port --dry-run（非 root）应成功"; fail=1; }
grep -q "DRY:.*lpadmin -p MyPrn" "$TMP/dry" || { echo "FAIL: set-port --dry-run 未打印命令"; fail=1; }
ESTUDIO_FAKE_UID=1000 "$CTL" --dry-run remove MyPrn >/dev/null 2>&1 \
    || { echo "FAIL: remove --dry-run（非 root）应成功"; fail=1; }
[ -s "$LOG" ] && { echo "FAIL: dry-run 不应执行外部命令"; fail=1; }
ok "set-port/remove --dry-run 免 root"

# --- app 包内布局：ctl 在 Contents/Resources，filter/PPD 与它同目录 ---
BUNDLE="$TMP/Bundle.app/Contents/Resources"
mkdir -p "$BUNDLE"
cp "$CTL" "$BUNDLE/estudioctl.sh"; chmod +x "$BUNDLE/estudioctl.sh"
: > "$BUNDLE/rastertoestudio"
: > "$BUNDLE/eSTUDIO2823AM.ppd"
out=$(env -u ESTUDIO_FILTER_SRC -u ESTUDIO_PPD_SRC \
      ESTUDIO_FILTER_DIR="$TMP/b/filter" ESTUDIO_PPD_DIR="$TMP/b/ppd" \
      ESTUDIO_CUPS_PPD_DIR="$CUPS_PPD_DIR" \
      "$BUNDLE/estudioctl.sh" --dry-run install-driver) \
    || { echo "FAIL: app 包内布局 install-driver --dry-run 失败"; fail=1; }
case "$out" in
    *"$BUNDLE/rastertoestudio"*"$BUNDLE/eSTUDIO2823AM.ppd"*) ;;
    *) echo "FAIL: app 包内布局未找到 filter/PPD：$out"; fail=1 ;;
esac
ok "app 包内布局能找到 filter/PPD"

# 删队列失败：告警 + 汇总 + 仍删驱动文件，但整体返回非 0
clear_log
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
if ESTUDIO_LPADMIN_FAIL=1 "$CTL" uninstall-driver --remove-queues >"$TMP/out" 2>"$TMP/err"; then
    echo "FAIL: 删队列失败时 uninstall-driver 应返回非 0"; fail=1
fi
grep -q "警告" "$TMP/err" || { echo "FAIL: 删队列失败时应输出警告"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] && { echo "FAIL: 删队列失败时仍应删除驱动 PPD"; fail=1; }
ok "uninstall-driver 逐队列软失败并汇总"

echo "ctl 基础检查：$([ "$fail" = 0 ] && echo 全部通过 || echo 有失败)"
exit "$fail"
