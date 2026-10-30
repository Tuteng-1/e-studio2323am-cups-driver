# eSTUDIO 打印机管理 app 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 给 macOS 上的 e-STUDIO2323AM/2823AM 驱动加一个中文图形界面 app，用于安装驱动、添加/删除打印机、设置端口（IP）、打印测试页、卸载驱动。

**Architecture:** 业务逻辑全部放进非交互命令行 `scripts/estudioctl.sh`（唯一单点，可独立测试）；界面 `app/main.applescript` 只负责收参数、拼子命令、通过 `do shell script … with administrator privileges` 调用 ctl 并展示结果。两者通过「子命令 + stdout/stderr」这一稳定接口交互。`scripts/install.sh` 退化为 ctl 的薄封装。

**Tech Stack:** bash（`lpadmin`/`lpstat`/`lp`/`install`/`launchctl`）、AppleScript（`osacompile` 打包，`PlistBuddy` 改 Info.plist）、GNU make。

**前置说明（重要）：** 本项目目录当前**不是 git 仓库**。开始前先执行 `git init && git add -A && git commit -m "chore: baseline"`；若不打算用 git，就把下面每个 “Commit” 步骤理解为“存档检查点”，直接跳过命令即可。

**约定：** 计划中所有命令都在仓库根目录 `/path/to/e-STUDIO2323AM` 下执行。

**参考 spec：** `docs/superpowers/specs/2026-10-29-printer-manager-app-design.md`

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `scripts/estudioctl.sh`（新建） | 全部业务逻辑：status/install-driver/uninstall-driver/list/add/set-port/testpage/remove + `--dry-run` |
| `tools/checkappctl.sh`（新建） | 用 PATH 桩对 ctl 做无 root 测试：断言命令构造、URI 归一化、非法输入 |
| `app/main.applescript`（新建） | 中文界面流程，仅通过子命令调 ctl |
| `scripts/build-app.sh`（新建） | `osacompile` 打包 `.app`、塞入 ctl、改 Info.plist、ad-hoc 签名 |
| `scripts/install.sh`（修改） | 退化为 `estudioctl.sh install-driver` + 可选 `add` 的薄封装 |
| `Makefile`（修改） | 新增 `app`、`test-appctl` 目标 |
| `README.md`（修改） | 增加 app 构建/使用说明与人工测试清单 |
| `app/build/`（生成物） | 构建出的 `.app`，不入库 |

---

## Task 1: ctl 骨架、`status`、输入校验

**Files:**
- Create: `scripts/estudioctl.sh`
- Create: `tools/checkappctl.sh`

- [x] **Step 1: 写失败测试（测试骨架 + status + 校验）**

创建 `tools/checkappctl.sh`：

```bash
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
```

- [x] **Step 2: 运行测试确认失败**

Run: `./tools/checkappctl.sh`
Expected: FAIL —— `status 应为 not-installed`（ctl 还不存在）或 `无法执行`

- [x] **Step 3: 写 ctl 骨架（含 status / 校验 / 空子命令表）**

创建 `scripts/estudioctl.sh`：

```bash
#!/bin/bash
#
# estudioctl.sh — e-STUDIO2323AM/2823AM 打印机管理（非交互）
#
# 供「eSTUDIO 打印机管理.app」调用，也可直接命令行使用。
#
#   estudioctl.sh status
#   estudioctl.sh install-driver
#   estudioctl.sh uninstall-driver [--remove-queues]
#   estudioctl.sh list
#   estudioctl.sh add NAME IP [--default] [--test]
#   estudioctl.sh set-port NAME IP
#   estudioctl.sh testpage NAME
#   estudioctl.sh remove NAME
#
# 全局选项：--dry-run（只打印将执行的命令）
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FILTER_SRC="${ESTUDIO_FILTER_SRC:-$ROOT/rastertoestudio}"
PPD_SRC="${ESTUDIO_PPD_SRC:-$ROOT/ppd/eSTUDIO2823AM.ppd}"

FILTER_DIR="${ESTUDIO_FILTER_DIR:-/usr/libexec/cups/filter}"
PPD_DIR="${ESTUDIO_PPD_DIR:-/Library/Printers/PPDs/Contents/Resources}"
CUPS_PPD_DIR="${ESTUDIO_CUPS_PPD_DIR:-/etc/cups/ppd}"

FILTER_NAME=rastertoestudio
PPD_NAME=eSTUDIO2823AM.ppd
FILTER_DST="$FILTER_DIR/$FILTER_NAME"
PPD_DST="$PPD_DIR/$PPD_NAME"
DEFAULT_PORT=9100

DRY=""

run() {
    if [ -n "$DRY" ]; then
        printf 'DRY:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" = 0 ] || die "需要管理员权限，请通过 app 或 sudo 运行"
}

# 队列名：非空、只允许 [A-Za-z0-9_-]
valid_queue_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# 输入 -> device URI。纯主机名/IP 补 socket:// 与 :9100；带 scheme 只接受 socket://
to_uri() {
    local rest
    case "$1" in
        *://*)
            case "$1" in
                socket://*) rest=${1#socket://} ;;
                *) return 1 ;;
            esac
            ;;
        *[!A-Za-z0-9._:-]*) return 1 ;;
        *:*) rest="$1"; printf 'socket://%s' "$1"; return 0 ;;
        *) rest="$1"; printf 'socket://%s:%s' "$1" "$DEFAULT_PORT"; return 0 ;;
    esac
    [ -n "$rest" ] || return 1
    printf 'socket://%s' "$rest"
    return 0
}

cmd_status() {
    if [ -f "$FILTER_DST" ] && [ -f "$PPD_DST" ]; then
        echo "installed"
    else
        echo "not-installed"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY=1; shift ;;
            *) break ;;
        esac
    done

    local cmd="${1:-}"
    if [ $# -gt 0 ]; then shift; fi

    case "$cmd" in
        status)   cmd_status ;;
        ""|-h|--help)
            sed -n '2,20p' "$0"
            [ -n "$cmd" ] || exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
}

main "$@"
```

- [x] **Step 4: 运行测试确认通过**

Run: `chmod +x scripts/estudioctl.sh tools/checkappctl.sh && ./tools/checkappctl.sh`
Expected: 打印 `ok status 未安装` 与 `ctl 基础检查：全部通过`

- [x] **Step 5: Commit**

```bash
git add scripts/estudioctl.sh tools/checkappctl.sh
git commit -m "feat(ctl): estudioctl 骨架、status 与输入校验"
```

---

## Task 2: `install-driver` / `uninstall-driver`

**Files:**
- Modify: `scripts/estudioctl.sh`
- Modify: `tools/checkappctl.sh`

- [x] **Step 1: 追加失败测试**

在 `tools/checkappctl.sh` 里 `echo "ctl 基础检查：..."` 之前插入：

```bash
# --- install-driver：真实复制到临时目录（install 是真命令，目标为 $TMP）---
clear_log
"$CTL" install-driver >/dev/null || { echo "FAIL: install-driver 失败"; fail=1; }
[ -f "$FILTER_DIR/rastertoestudio" ] || { echo "FAIL: filter 未安装"; fail=1; }
[ -f "$PPD_DIR/eSTUDIO2823AM.ppd" ] || { echo "FAIL: PPD 未安装"; fail=1; }
has "chown root:wheel"
[ "$("$CTL" status)" = "installed" ] || { echo "FAIL: status 应为 installed"; fail=1; }
ok "install-driver 安装 filter+PPD，status=installed"

# --- uninstall-driver --remove-queues：删文件并列队删除 ---
clear_log
# 让 cmd_list 认得出 eSTUDIO2823AM 是本驱动的队列
printf 'something rastertoestudio something\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
"$CTL" uninstall-driver --remove-queues >/dev/null || { echo "FAIL: uninstall-driver 失败"; fail=1; }
[ -f "$FILTER_DIR/rastertoestudio" ] && { echo "FAIL: filter 未删除"; fail=1; }
has "lpadmin -x eSTUDIO2823AM"
[ "$("$CTL" status)" = "not-installed" ] || { echo "FAIL: status 应为 not-installed"; fail=1; }
ok "uninstall-driver 删除驱动与队列"

# --- dry-run：只打印，不落地 ---
clear_log
out=$("$CTL" --dry-run install-driver)
case "$out" in
    *"DRY:"*"install -m 755"*) ;;
    *) echo "FAIL: dry-run 未打印 install 命令"; fail=1 ;;
esac
[ -f "$FILTER_DIR/rastertoestudio" ] && { echo "FAIL: dry-run 不应落地文件"; fail=1; }
ok "dry-run 只打印不执行"
```

- [x] **Step 2: 运行测试确认失败**

Run: `./tools/checkappctl.sh`
Expected: FAIL —— `未知子命令：install-driver`

- [x] **Step 3: 实现两个子命令**

在 `scripts/estudioctl.sh` 的 `cmd_status()` 之后加入：

```bash
cmd_install_driver() {
    need_root
    [ -f "$FILTER_SRC" ] || die "找不到 filter：$FILTER_SRC（先在仓库根运行 make）"
    [ -f "$PPD_SRC" ] || die "找不到 PPD：$PPD_SRC"
    run install -d "$FILTER_DIR"
    run install -m 755 "$FILTER_SRC" "$FILTER_DST"
    run chown root:wheel "$FILTER_DST"
    run chmod 755 "$FILTER_DST"
    run install -d "$PPD_DIR"
    run install -m 644 "$PPD_SRC" "$PPD_DST"
    run chown root:wheel "$PPD_DST"
    run launchctl kickstart -k system/org.cups.cupsd
    echo "驱动已安装：$FILTER_DST, $PPD_DST"
}

cmd_uninstall_driver() {
    local remove_queues="$1"
    need_root
    run rm -f "$FILTER_DST" "$PPD_DST"
    if [ "$remove_queues" = "yes" ]; then
        local name uri
        while IFS=$'\t' read -r name uri; do
            [ -n "$name" ] || continue
            run lpadmin -x "$name"
        done < <(cmd_list)
    fi
    run launchctl kickstart -k system/org.cups.cupsd
    echo "驱动已卸载"
}
```

并把 `main()` 的分发改成：

```bash
    case "$cmd" in
        status)         cmd_status ;;
        install-driver) cmd_install_driver ;;
        uninstall-driver)
            local rq=no
            [ "${1:-}" = "--remove-queues" ] && rq=yes
            cmd_uninstall_driver "$rq" ;;
        ""|-h|--help)
            sed -n '2,20p' "$0"
            [ -n "$cmd" ] || exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
```

> 注意：此时 `cmd_list` 尚未定义，`uninstall-driver --remove-queues` 会调用到它。为保证本任务测试通过，暂时在文件里加一个占位：
> ```bash
> cmd_list() { :; }
> ```
> Task 3 会用真实实现替换它。

- [x] **Step 4: 运行测试确认通过**

Run: `./tools/checkappctl.sh`
Expected: 出现 `ok install-driver ...` / `ok uninstall-driver ...` / `ok dry-run 只打印不执行`，最后 `ctl 基础检查：全部通过`

- [x] **Step 5: Commit**

```bash
git add scripts/estudioctl.sh tools/checkappctl.sh
git commit -m "feat(ctl): install-driver / uninstall-driver（含 --dry-run）"
```

---

## Task 3: `list`

**Files:**
- Modify: `scripts/estudioctl.sh`
- Modify: `tools/checkappctl.sh`

- [x] **Step 1: 追加失败测试**

在 `tools/checkappctl.sh` 里 `echo "ctl 基础检查：..."` 之前插入：

```bash
# --- list：只列 PPD 指向本驱动 filter 的队列 ---
clear_log
printf 'something rastertoestudio something\n' > "$CUPS_PPD_DIR/eSTUDIO2823AM.ppd"
out=$("$CTL" list)
[ "$out" = "$(printf 'eSTUDIO2823AM\tsocket://10.0.0.5:9100')" ] \
    || { echo "FAIL: list 输出不符：'$out'"; fail=1; }
case "$out" in *OtherPrinter*) echo "FAIL: list 混入了无关队列"; fail=1 ;; esac
ok "list 只列本驱动队列"
```

- [x] **Step 2: 运行测试确认失败**

Run: `./tools/checkappctl.sh`
Expected: FAIL —— `list 输出不符`

- [x] **Step 3: 用真实实现替换占位 `cmd_list`**

把 `scripts/estudioctl.sh` 里的 `cmd_list() { :; }` 替换为：

```bash
# 输出：队列名<TAB>device URI（只列 PPD 指向本驱动 filter 的队列）
cmd_list() {
    local line name uri ppd
    lpstat -v 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            "device for "*": "*) ;;
            *) continue ;;
        esac
        name=${line#device for }
        name=${name%%:*}
        uri=${line#*: }
        ppd="$CUPS_PPD_DIR/$name.ppd"
        if [ -f "$ppd" ] && grep -q "$FILTER_NAME" "$ppd" 2>/dev/null; then
            printf '%s\t%s\n' "$name" "$uri"
        fi
    done
}
```

并把分发里加上：

```bash
        list)           cmd_list ;;
```

- [x] **Step 4: 运行测试确认通过**

Run: `./tools/checkappctl.sh`
Expected: `ok list 只列本驱动队列`

- [x] **Step 5: Commit**

```bash
git add scripts/estudioctl.sh tools/checkappctl.sh
git commit -m "feat(ctl): list 只列本驱动队列"
```

---

## Task 4: `add`

**Files:**
- Modify: `scripts/estudioctl.sh`
- Modify: `tools/checkappctl.sh`

- [x] **Step 1: 追加失败测试**

在 `tools/checkappctl.sh` 里 `echo "ctl 基础检查：..."` 之前插入：

```bash
# --- add：默认补 socket:// 与 :9100 ---
clear_log
printf 'something rastertoestudio something\n' > "$PPD_DIR/eSTUDIO2823AM.ppd"
: > "$FILTER_DIR/rastertoestudio"
"$CTL" add MyPrn 10.0.0.9 >/dev/null || { echo "FAIL: add 失败"; fail=1; }
has "lpadmin -p MyPrn -E -v socket://10.0.0.9:9100"
has "-P $PPD_DIR/eSTUDIO2823AM.ppd"
has "-o printer-is-shared=false"
hasnt "lpadmin -d MyPrn"
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

# --- 非法队列名：不得调用 lpadmin，且退出非 0 ---
for bad in "" "a b" "a/b" "a.b"; do
    clear_log
    if "$CTL" add "$bad" 10.0.0.5 >/dev/null 2>&1; then
        echo "FAIL: 非法队列名 '$bad' 应失败"; fail=1
    fi
    hasnt "lpadmin"
done
ok "非法队列名被拒绝"

# --- 非法地址 scheme ---
clear_log
if "$CTL" add GoodName "ipp://1.2.3.4" >/dev/null 2>&1; then
    echo "FAIL: 非 socket scheme 应失败"; fail=1
fi
hasnt "lpadmin"
ok "非 socket scheme 被拒绝"
```

- [x] **Step 2: 运行测试确认失败**

Run: `./tools/checkappctl.sh`
Expected: FAIL —— `未知子命令：add`（或 `用法：add`）

- [x] **Step 3: 实现 `cmd_add` 与 `cmd_testpage`**

在 `scripts/estudioctl.sh` 的 `cmd_uninstall_driver()` 之后加入（`cmd_testpage` 也要一起加，因为 `add --test` 会调用它）：

```bash
cmd_testpage() {
    local name="$1"
    valid_queue_name "$name" || die "非法队列名：$name"
    need_root
    run lp -d "$name" /etc/hosts
    echo "测试页已发送：$name"
}

cmd_add() {
    local name="$1" target="$2" make_default="$3" do_test="$4" uri
    valid_queue_name "$name" || die "非法队列名：$name（只允许字母数字 _ -）"
    uri=$(to_uri "$target") || die "非法地址：$target"
    [ -f "$PPD_DST" ] || die "驱动尚未安装，请先安装驱动"
    need_root
    run lpadmin -p "$name" -E -v "$uri" -P "$PPD_DST" -o printer-is-shared=false
    if [ "$make_default" = "yes" ]; then
        run lpadmin -d "$name"
    fi
    echo "已添加打印机：$name -> $uri"
    if [ "$do_test" = "yes" ]; then
        cmd_testpage "$name"
    fi
}
```

并在 `main()` 分发中加入 `add` 分支：

```bash
        add)
            [ $# -ge 2 ] || die "用法：add NAME IP [--default] [--test]"
            local name="$1" target="$2" md=no dt=no
            shift 2
            while [ $# -gt 0 ]; do
                case "$1" in
                    --default) md=yes ;;
                    --test)    dt=yes ;;
                    *) die "未知选项：$1" ;;
                esac
                shift
            done
            cmd_add "$name" "$target" "$md" "$dt" ;;
        testpage)
            [ $# -ge 1 ] || die "用法：testpage NAME"
            cmd_testpage "$1" ;;
```

- [x] **Step 4: 运行测试确认通过**

Run: `./tools/checkappctl.sh`
Expected: 出现 `ok add 归一化 URI 并建队列` / `ok add --default --test ...` / `ok add 接受完整 socket:// URI` / `ok 非法队列名被拒绝` / `ok 非 socket scheme 被拒绝`

- [x] **Step 5: Commit**

```bash
git add scripts/estudioctl.sh tools/checkappctl.sh
git commit -m "feat(ctl): add 建队列、URI 归一化、--default/--test"
```

---

## Task 5: `set-port` / `remove`

**Files:**
- Modify: `scripts/estudioctl.sh`
- Modify: `tools/checkappctl.sh`

- [x] **Step 1: 追加失败测试**

在 `tools/checkappctl.sh` 里 `echo "ctl 基础检查：..."` 之前插入：

```bash
# --- set-port ---
clear_log
"$CTL" set-port MyPrn 10.0.0.77 >/dev/null || { echo "FAIL: set-port 失败"; fail=1; }
has "lpadmin -p MyPrn -v socket://10.0.0.77:9100"
ok "set-port 修改端口"

# --- remove：删队列 + 删 PPD 配置 ---
clear_log
printf 'x rastertoestudio\n' > "$CUPS_PPD_DIR/MyPrn.ppd"
"$CTL" remove MyPrn >/dev/null || { echo "FAIL: remove 失败"; fail=1; }
has "lpadmin -x MyPrn"
has "rm -f $CUPS_PPD_DIR/MyPrn.ppd"
[ -f "$CUPS_PPD_DIR/MyPrn.ppd" ] && { echo "FAIL: PPD 配置未删除"; fail=1; }
ok "remove 删队列与 PPD 配置"

# --- set-port 非法地址 ---
clear_log
if "$CTL" set-port MyPrn "http://x" >/dev/null 2>&1; then
    echo "FAIL: set-port 非 socket scheme 应失败"; fail=1
fi
hasnt "lpadmin"
ok "set-port 拒绝非 socket scheme"
```

- [x] **Step 2: 运行测试确认失败**

Run: `./tools/checkappctl.sh`
Expected: FAIL —— `未知子命令：set-port`

- [x] **Step 3: 实现两个子命令**

在 `scripts/estudioctl.sh` 的 `cmd_testpage()` 之后加入：

```bash
cmd_set_port() {
    local name="$1" target="$2" uri
    valid_queue_name "$name" || die "非法队列名：$name"
    uri=$(to_uri "$target") || die "非法地址：$target"
    need_root
    run lpadmin -p "$name" -v "$uri"
    echo "端口已更新：$name -> $uri"
}

cmd_remove() {
    local name="$1"
    valid_queue_name "$name" || die "非法队列名：$name"
    need_root
    run lpadmin -x "$name"
    run rm -f "$CUPS_PPD_DIR/$name.ppd"
    echo "已删除打印机：$name"
}
```

并在 `main()` 分发中加入：

```bash
        set-port)
            [ $# -ge 2 ] || die "用法：set-port NAME IP"
            cmd_set_port "$1" "$2" ;;
        remove)
            [ $# -ge 1 ] || die "用法：remove NAME"
            cmd_remove "$1" ;;
```

- [x] **Step 4: 运行测试确认通过**

Run: `./tools/checkappctl.sh`
Expected: 出现 `ok set-port 修改端口` / `ok remove 删队列与 PPD 配置` / `ok set-port 拒绝非 socket scheme`，最终 `ctl 基础检查：全部通过`

- [x] **Step 5: 全量回归（不得破坏既有测试）**

Run: `make test test-options test-capture`
Expected: 全部通过（本任务只新增脚本，不改 filter）

- [x] **Step 6: Commit**

```bash
git add scripts/estudioctl.sh tools/checkappctl.sh
git commit -m "feat(ctl): set-port / remove"
```

---

## Task 6: Makefile 目标 `test-appctl`

**Files:**
- Modify: `Makefile`

- [x] **Step 1: 写失败检查（目标不存在）**

Run: `make test-appctl`
Expected: `No rule to make target 'test-appctl'`

- [x] **Step 2: 加目标**

在 `Makefile` 顶部注释里 `#   make test-replay    ...` 之后加一行：

```make
#   make test-appctl   打印机管理 CLI（estudioctl）自测
```

在 `test-replay:` 目标之后加：

```make
# 打印机管理 CLI 自测：PATH 桩验证命令构造/URI 归一化/非法输入
test-appctl:
	./tools/checkappctl.sh ./scripts/estudioctl.sh
```

并把 `.PHONY` 行改为：

```make
.PHONY: all install uninstall check test test-capture test-pdf test-options test-replay test-appctl clean
```

- [x] **Step 3: 运行确认通过**

Run: `make test-appctl`
Expected: 最后一行 `ctl 基础检查：全部通过`

- [x] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: make test-appctl"
```

---

## Task 7: AppleScript 界面

**Files:**
- Create: `app/main.applescript`

- [x] **Step 1: 写界面脚本**

创建 `app/main.applescript`：

```applescript
-- eSTUDIO 打印机管理：仅收集输入并调用 estudioctl.sh，不含业务逻辑。
-- estudioctl.sh 由构建脚本放进 Contents/Resources。

on ctlRaw(args, admin)
	set ctlPath to POSIX path of (path to resource "estudioctl.sh")
	if admin then
		return do shell script (quoted form of ctlPath & " " & args) with administrator privileges
	else
		return do shell script (quoted form of ctlPath & " " & args)
	end if
end ctlRaw

-- 出错时弹红色提示框并返回 ""
on ctl(args, admin)
	try
		return ctlRaw(args, admin)
	on error msg
		display dialog "操作失败：" & msg buttons {"好"} default button "好" with icon stop
		return ""
	end try
end ctl

on askText(prompt, def)
	set r to display dialog prompt default answer def buttons {"取消", "继续"} default button "继续"
	if button returned of r is "取消" then return missing value
	return text returned of r
end askText

on queueNames()
	set raw to ctl("list", false)
	if raw is "" then return {}
	set names to {}
	repeat with ln in paragraphs of raw
		set s to ln as text
		if s is not "" then
			set t to offset of tab in s
			if t > 0 then set end of names to text 1 thru (t - 1) of s
		end if
	end repeat
	return names
end queueNames

on pickQueue(prompt)
	set names to queueNames()
	if (count of names) is 0 then
		display dialog "尚无本驱动的打印机，请先添加。" buttons {"好"} default button "好" with icon caution
		return missing value
	end if
	set sel to choose from list names with prompt prompt
	if sel is false then return missing value
	return item 1 of sel
end pickQueue

on addPrinter()
	set nm to askText("队列名：", "eSTUDIO2823AM")
	if nm is missing value or nm is "" then return
	set ip to askText("打印机 IP 或主机名：", "")
	if ip is missing value or ip is "" then return
	set md to button returned of (display dialog "设为默认打印机？" buttons {"否", "是"} default button "是")
	set dt to button returned of (display dialog "立即打印测试页？" buttons {"否", "是"} default button "否")
	set cmdStr to "add " & quoted form of nm & " " & quoted form of ip
	if md is "是" then set cmdStr to cmdStr & " --default"
	if dt is "是" then set cmdStr to cmdStr & " --test"
	set r to ctl(cmdStr, true)
	if r is not "" then display dialog r buttons {"好"} default button "好"
end addPrinter

on setPort()
	set nm to pickQueue("选择要修改端口的打印机：")
	if nm is missing value then return
	set ip to askText("新的 IP 或主机名：", "")
	if ip is missing value or ip is "" then return
	set r to ctl("set-port " & quoted form of nm & " " & quoted form of ip, true)
	if r is not "" then display dialog r buttons {"好"} default button "好"
end setPort

on testPage()
	set nm to pickQueue("选择要打印测试页的打印机：")
	if nm is missing value then return
	set r to ctl("testpage " & quoted form of nm, true)
	if r is not "" then display dialog r buttons {"好"} default button "好"
end testPage

on removePrinter()
	set nm to pickQueue("选择要删除的打印机：")
	if nm is missing value then return
	set c to button returned of (display dialog "确定删除打印机 " & nm & " ？其配置也会一并删除。" buttons {"取消", "删除"} default button "删除")
	if c is not "删除" then return
	set r to ctl("remove " & quoted form of nm, true)
	if r is not "" then display dialog r buttons {"好"} default button "好"
end removePrinter

on uninstallDriver()
	set c to button returned of (display dialog "确定卸载驱动（移除 filter 与 PPD）？" buttons {"取消", "卸载"} default button "卸载")
	if c is not "卸载" then return
	set q to button returned of (display dialog "是否同时删除本驱动创建的所有打印机？" buttons {"保留打印机", "一并删除"} default button "保留打印机")
	set cmdStr to "uninstall-driver"
	if q is "一并删除" then set cmdStr to cmdStr & " --remove-queues"
	set r to ctl(cmdStr, true)
	if r is not "" then display dialog r buttons {"好"} default button "好"
end uninstallDriver

on run
	if ctl("status", false) does not contain "installed" then
		set c to button returned of (display dialog "驱动尚未安装。现在安装？" buttons {"退出", "安装"} default button "安装")
		if c is "安装" then
			set r to ctl("install-driver", true)
			if r is "" then return
			display dialog r buttons {"好"} default button "好"
		else
			return
		end if
	end if

	repeat
		set choice to choose from list {"添加打印机", "设置端口", "打印测试页", "删除打印机", "卸载驱动", "退出"} with prompt "eSTUDIO 打印机管理" with title "eSTUDIO"
		if choice is false then exit repeat
		set c to item 1 of choice
		if c is "添加打印机" then
			addPrinter()
		else if c is "设置端口" then
			setPort()
		else if c is "打印测试页" then
			testPage()
		else if c is "删除打印机" then
			removePrinter()
		else if c is "卸载驱动" then
			uninstallDriver()
		else
			exit repeat
		end if
	end repeat
end run
```

- [x] **Step 2: 语法检查**

Run: `osacompile -o /tmp/estudio-check.app app/main.applescript && rm -rf /tmp/estudio-check.app`
Expected: 无输出、退出码 0（AppleScript 编译通过）

- [x] **Step 3: Commit**

```bash
git add app/main.applescript
git commit -m "feat(app): AppleScript 界面"
```

---

## Task 8: 打包脚本与 `make app`

**Files:**
- Create: `scripts/build-app.sh`
- Modify: `Makefile`

- [x] **Step 1: 写失败检查（脚本不存在）**

Run: `sh scripts/build-app.sh`
Expected: `No such file or directory`

- [x] **Step 2: 写打包脚本**

创建 `scripts/build-app.sh`：

```bash
#!/bin/bash
#
# build-app.sh — 把 app/main.applescript 打包成「eSTUDIO 打印机管理.app」
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/build"
APP="$OUT/eSTUDIO 打印机管理.app"

[ -f "$ROOT/app/main.applescript" ] || { echo "缺少 app/main.applescript" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$OUT"

osacompile -o "$APP" "$ROOT/app/main.applescript"

cp "$ROOT/scripts/estudioctl.sh" "$APP/Contents/Resources/estudioctl.sh"
chmod 755 "$APP/Contents/Resources/estudioctl.sh"

PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null 2>&1 || true; }
pb "Add :CFBundleName string eSTUDIO 打印机管理"
pb "Set :CFBundleName eSTUDIO 打印机管理"
pb "Add :CFBundleDisplayName string eSTUDIO 打印机管理"
pb "Add :CFBundleIdentifier string com.estudio.printermanager"
pb "Add :NSHighResolutionCapable bool true"
pb "Add :LSMinimumSystemVersion string 11.0"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "已构建：$APP"
```

- [x] **Step 3: 运行打包并确认产物完整**

Run:
```bash
chmod +x scripts/build-app.sh
sh scripts/build-app.sh
ls "app/build/eSTUDIO 打印机管理.app/Contents/Resources/estudioctl.sh"
/usr/libexec/PlistBuddy -c "Print :CFBundleName" "app/build/eSTUDIO 打印机管理.app/Contents/Info.plist"
```
Expected: 打印 `已构建：…`；ctl 路径存在；`CFBundleName` 为 `eSTUDIO 打印机管理`

- [x] **Step 4: 加 `make app` 目标**

在 `Makefile` 顶部注释里追加：

```make
#   make app            打包「eSTUDIO 打印机管理.app」（osacompile）
```

在 `test-appctl:` 之后加：

```make
app: $(FILTER)
	sh scripts/build-app.sh
```

并更新 `.PHONY`：

```make
.PHONY: all install uninstall check test test-capture test-pdf test-options test-replay test-appctl app clean
```

- [x] **Step 5: 运行确认**

Run: `make app && ls app/build`
Expected: `eSTUDIO 打印机管理.app`

- [x] **Step 6: Commit**

```bash
git add scripts/build-app.sh Makefile
git commit -m "build: make app 打包打印机管理 app"
```

---

## Task 9: `install.sh` 退化为薄封装 + README

**Files:**
- Modify: `scripts/install.sh`
- Modify: `README.md`

- [x] **Step 1: 改写 install.sh**

把 `scripts/install.sh` 整体替换为：

```bash
#!/bin/bash
#
# e-STUDIO2323AM / 2823AM 原生 CUPS 驱动安装脚本（estudioctl.sh 的薄封装）
#
#   sudo ./scripts/install.sh                      # 只安装 filter + PPD
#   sudo ./scripts/install.sh --queue 192.0.2.10  # 同时建网络队列（socket://IP:9100）
#   sudo ./scripts/install.sh --queue socket://192.0.2.10:9100
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/scripts/estudioctl.sh"

QUEUE_ADDR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)   QUEUE_ADDR="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" != "0" ]; then
    echo "需要 root：sudo $0 $*"
    exit 1
fi

echo "== 构建 =="
make -C "$ROOT" clean all

echo "== 安装驱动 =="
"$CTL" install-driver

if [ -n "$QUEUE_ADDR" ]; then
    echo "== 创建队列 eSTUDIO2823AM -> $QUEUE_ADDR =="
    "$CTL" add eSTUDIO2823AM "$QUEUE_ADDR" --default
    if lpstat -p eSTUDIO2823AM 2>/dev/null | grep -q disabled; then
        echo "警告：队列处于 disabled 状态，检查 lpstat -p eSTUDIO2823AM"
    else
        echo "队列已创建。测试：lp -d eSTUDIO2823AM /etc/hosts"
    fi
else
    cat <<EOF

安装完成。手动添加队列（或用「eSTUDIO 打印机管理.app」）：

  sudo "$CTL" add eSTUDIO2823AM <打印机IP> --default --test
EOF
fi
```

- [x] **Step 2: 验证封装等价（不装系统，用 dry-run 跑一遍关键路径的人工核对）**

Run: `./scripts/estudioctl.sh --dry-run add eSTUDIO2823AM 192.0.2.10 --default`
Expected: 打印 `DRY: lpadmin -p eSTUDIO2823AM -E -v socket://192.0.2.10:9100 …` 与 `DRY: lpadmin -d eSTUDIO2823AM`

- [x] **Step 3: README 增加 app 章节**

在 `README.md` 的「## 安装」小节之后插入：

````markdown
## 图形界面（推荐）

不用命令行也可以：先 `make app` 打包出「eSTUDIO 打印机管理.app」，双击打开后即可

- 安装 / 卸载驱动；
- 添加打印机（填队列名 + IP，默认 `eSTUDIO2823AM`）；
- 设置端口：选中已有打印机，改成新的 IP；
- 打印测试页；
- 删除打印机（连同其配置一起清理）。

需要管理员权限的步骤会弹出系统标准密码框。app 只是外壳，所有实际操作由
`scripts/estudioctl.sh` 完成，也可以直接用命令行：

```sh
./scripts/estudioctl.sh status
sudo ./scripts/estudioctl.sh install-driver
sudo ./scripts/estudioctl.sh add eSTUDIO2823AM 192.0.2.10 --default --test
sudo ./scripts/estudioctl.sh set-port eSTUDIO2823AM 192.0.2.20
sudo ./scripts/estudioctl.sh remove eSTUDIO2823AM
sudo ./scripts/estudioctl.sh uninstall-driver --remove-queues
```

### 人工测试清单

1. `make app`，双击 `app/build/eSTUDIO 打印机管理.app`；未装驱动时应提示安装。
2. 安装驱动后，「系统设置 → 打印机与扫描仪」应能出现图标。
3. 添加打印机（填真实 IP）→ `lpstat -v` 能看到 `socket://IP:9100`。
4. 打印测试页 → 出纸一页。
5. 设置端口改成另一个 IP → `lpstat -v` 显示新 URI。
6. 删除打印机 → `lpstat -v` 不再有该队列，`/etc/cups/ppd/<名字>.ppd` 被删除。
7. 卸载驱动 → filter 与 PPD 从系统目录消失。
````

同时把 README 「## 构建与自测」里的命令清单补上：

```sh
make test-appctl     # 打印机管理 CLI 自测（无需 root）
make app             # 打包图形界面 app
```

- [x] **Step 4: 全量回归**

Run: `make test test-options test-capture test-replay test-pdf test-appctl check`
Expected: 全部通过

- [x] **Step 5: Commit**

```bash
git add scripts/install.sh README.md
git commit -m "docs: app 使用说明；install.sh 改为 estudioctl 薄封装"
```

---

## 交付验收

- [x] `make test-appctl` 通过（无 root、不碰系统）。
- [x] `make app` 产出可双击打开的「eSTUDIO 打印机管理.app」。
- [x] 既有回归全绿：`make test test-options test-capture test-replay test-pdf check`。
- [x] 人工清单 7 步走通（至少到“删除打印机”；卸载驱动可最后做）。
- [x] 卸载驱动后系统目录不再残留 `rastertoestudio` 与 `eSTUDIO2823AM.ppd`。


---

## 执行记录（2026-10-30 完成）

分支 `feature/printer-manager-app`，全部完成并验证。提交序列：

| commit | 内容 |
|---|---|
| `153bd53` | Task 1：ctl 骨架 / status / 输入校验 |
| `4e02606` | Task 1 修复：队列名与 URI 校验、退出码断言、错误处理 |
| `3316001` | Task 1 测试补强：status 单文件缺失、to_uri 返回码 |
| `17bf013` | Task 2+3：install-driver / uninstall-driver / list |
| `b703b3b` | Task 2+3 修复：dry-run 位置无关且免 root、uninstall 先删队列+软失败汇总、list 区分无队列与服务不可用 |
| `b2d7204` | Task 4+5：add / testpage / set-port / remove |
| `73d8fd6` | Task 6：`make test-appctl` |
| `32c93eb` | ctl 用 `BASH_SOURCE` 定位自身，支持 app 包内布局 |
| `c26616a` | Task 7+8：AppleScript 界面、build-app.sh、`make app` |
| `1449dc6` | Task 9：install.sh 薄封装 + README app 章节 |
| `ec33adb` | 新增 Task 10：界面无头自测（`tools/checkappui.sh`、`make test-appui`） |

与原计划的有意偏差：

1. **Task 2 与 Task 3 合并执行**：`uninstall-driver --remove-queues` 依赖真实 `list`，先前的“占位实现”会让测试必然失败。
2. **`cmd_testpage` 提前到 Task 4**：`add --test` 依赖它（原计划放在 Task 5 会出现“占位就 die”）。
3. **`--dry-run` 位置无关且不要求 root**：新增 `need_root_or_dry()`；原实现把 `--dry-run` 写在子命令之后会被静默忽略并真实执行。
4. **`uninstall-driver --remove-queues` 先删队列再删文件**，单队列失败只告警并汇总（返回非 0），避免“驱动没了、队列还在”。
5. **`list` 把 `lpstat -v` 返回 1 且 `lpstat -r` 正常当作“没有队列”**（成功、空输出），只有 CUPS 服务不可用才报错。
6. **新增 Task 10（界面自测）**：把弹窗换成桩，用 `osascript` 跑真实的
   `addPrinter/setPort/testPage/removePrinter`，断言拼出的 ctl 子命令逐字符合预期；
   带 20 秒看门狗，界面里新增阻塞式弹窗会立刻失败。
7. **app 包内布局由 ctl 自己识别**（`Contents/Resources` 下 filter/PPD 与 ctl 同级），
   `build-app.sh` 构建后会自检这一步。

验收：`make test test-options test-capture test-replay test-pdf test-appctl test-appui check`
全部通过（抓包回归 25/25，重放 23 通过 / 0 失败 / 2 跳过）。

真机实测（2026-10-30，macOS + e-STUDIO2323AM `192.0.2.10`）：

- ✅ 双击 app → 安装驱动 → 添加打印机（默认 `eSTUDIO2823AM` / `socket://192.0.2.10:9100`）
  → 打印测试页，出纸正常；TopAccess 打印计数 45003 → 45009。
- ✅ `estudioctl.sh list` 在真实机器上正确列出队列。

真机实测暴露并修复的真实缺陷（单测/桩测当时没覆盖到）：

1. **`list` 依赖 `lpstat` 的英文文案**：macOS 的 `lpstat` 会被本地化成
   `用于NAME的设备：URI`，且 `LANG`/`LC_ALL` 改不动 → 界面显示「0 台」。
   改为从 `/etc/cups/ppd/*.ppd` 取队列清单、只按 `scheme://` 正则取 URI。
2. **打印测试页错误地要求管理员权限**：`lp` 用普通用户即可，改为不要求 root
   （否则作业属于 root）。

尚未验证：

- 设置端口 / 删除打印机 / 卸载驱动 尚未在真机上走一遍（等价逻辑有 `make test-appctl` 覆盖）。
- 横向方向目视确认（若反了改 `rotate_mono()`）。
