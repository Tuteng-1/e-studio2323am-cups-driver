#!/bin/bash
#
# checkappui.sh — 无头验证「eSTUDIO 打印机管理.app」的 AppleScript 界面逻辑
#
# 原理：把 app/main.applescript 里的“弹窗”handler（ctlRaw / askText / confirm / say）
# 换成桩，再补一个测试用 on run，用 osascript 跑真正的 addPrinter / setPort /
# testPage / removePrinter，断言它拼出的 estudioctl.sh 子命令完全符合预期。
#
# 不需要 root、不弹窗、不碰系统。
#
#   ./tools/checkappui.sh [app/main.applescript]
#
set -u

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-$ROOT_DIR/app/main.applescript}
[ -f "$SRC" ] || { echo "FAIL: 找不到 $SRC"; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/estudio-ui.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd)
trap 'rm -rf "$TMP"' EXIT

CAP="$TMP/capture.log"
BIN="$TMP/bin"
PPDS="$TMP/ppds"
mkdir -p "$BIN" "$PPDS"

# 一个本驱动队列 + 一个无关队列
cat > "$BIN/lpstat" <<'EOF'
#!/bin/bash
case "${1:-}" in -r) echo "scheduler is running"; exit 0 ;; esac
printf 'device for eSTUDIO2823AM: socket://10.0.0.5:9100\n'
printf 'device for OtherPrinter: ipp://x/y\n'
EOF
chmod +x "$BIN/lpstat"
printf '*cupsFilter: "application/vnd.cups-raster 0 rastertoestudio"\n' > "$PPDS/eSTUDIO2823AM.ppd"

# 生成探针脚本
python3 - "$SRC" "$TMP/probe.applescript" "$CAP" <<'PY' || exit 2
import sys
src, dst, cap = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()

marker = "on run\n"
if marker not in s:
    sys.exit("FAIL: main.applescript 里找不到 on run")
s = s[:s.index(marker)]

cap_lit = cap.replace("\\", "\\\\").replace('"', '\\"')
ctl_stub = '''\tif args is "list" then return "TestQ" & tab & "socket://10.9.9.9:9100"
\tset cmdLine to args
\tif admin then set cmdLine to cmdLine & " [ADMIN]"
\tdo shell script "printf '%s\\\\n' " & quoted form of cmdLine & " >> __CAP__"
\treturn "OK"'''.replace("__CAP__", cap_lit)

subs = [
    # ctlRaw -> 记录子命令（list 返回固定队列行）
    ('''\tset ctlPath to POSIX path of (path to resource ctlFile)
\tset cmdStr to quoted form of ctlPath & " " & args
\tif admin then
\t\treturn do shell script cmdStr with administrator privileges
\telse
\t\treturn do shell script cmdStr
\tend if''',
     ctl_stub),
    # askText -> 固定输入
    ('''\tset r to display dialog prompt default answer def buttons {"取消", "继续"} default button "继续" with title "eSTUDIO 打印机管理"
\tif button returned of r is "取消" then return missing value
\treturn text returned of r''',
     '''\tif prompt contains "NotUsed" then return missing value
\tif prompt contains "队列名" then return "TestQ"
\treturn "10.9.9.9"'''),
    # confirm -> 一律确认
    ('''\tset r to display dialog prompt buttons {"取消", okLabel} default button okLabel with title "eSTUDIO 打印机管理"
\treturn (button returned of r is okLabel)''',
     '''\treturn true'''),
    # say -> 静默
    ('''\tdisplay dialog msg buttons {"好"} default button "好" with title "eSTUDIO 打印机管理"''',
     '''\treturn'''),
    # pickQueue 的选择列表 -> 直接选第一个
    ('''\tset sel to choose from list labels with prompt prompt with title "eSTUDIO 打印机管理"
\tif sel is false then return missing value
\tset chosen to item 1 of sel''',
     '''\tset chosen to item 1 of labels'''),
]

for old, new in subs:
    if old not in s:
        sys.exit("FAIL: 无法在 main.applescript 中定位待替换的 handler（界面代码改动后请同步更新本测试）")
    s = s.replace(old, new, 1)

s += '''on run
\taddPrinter()
\tsetPort()
\ttestPage()
\tremovePrinter()
\tshowStatus()
\treturn "done"
end run
'''
open(dst, "w").write(s)
PY

APP="$TMP/Probe.app"
osacompile -o "$APP" "$TMP/probe.applescript" || { echo "FAIL: osacompile 失败"; exit 2; }

# 探针只调用 ctlRaw 桩，不需要真的 ctl，但保留入口以便解析 queueList
# 后台跑 + 超时看门狗：任何没被替换掉的弹窗都会让它卡住，这里必须能杀掉
PATH="$BIN:${PATH:-/usr/bin:/bin}" ESTUDIO_CUPS_PPD_DIR="$PPDS" \
    osascript "$APP" > "$TMP/out" 2>"$TMP/err" &
pid=$!
for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo "FAIL: 界面探针超时（可能有未替换的弹窗，或新增了会阻塞的界面调用）"
    exit 1
fi
wait "$pid" || { echo "FAIL: 探针执行失败"; sed 's/^/  /' "$TMP/err"; exit 1; }
grep -qx "done" "$TMP/out" || { echo "FAIL: 探针未正常结束：$(cat "$TMP/out")"; exit 1; }

# [ADMIN] = 会弹管理员密码框。只有改系统配置的操作才需要，打印测试页不需要
expected="add 'TestQ' '10.9.9.9' --default --test [ADMIN]
set-port 'TestQ' '10.9.9.9' [ADMIN]
testpage 'TestQ'
remove 'TestQ' [ADMIN]
status"

if ! diff -u <(printf '%s\n' "$expected") "$CAP"; then
    echo "FAIL: 界面生成的 ctl 子命令与预期不符"
    exit 1
fi

echo "ok   界面生成 ctl 子命令（add/--default/--test、set-port、testpage、remove）"
echo "界面自检：全部通过"
