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

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

run() {
    if [ -n "$DRY" ]; then
        printf 'DRY:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@" || die "命令失败（退出码 $?）：$*"
}

# 执行但不中断，返回命令自身退出状态（dry-run 恒 0）
run_soft() {
    if [ -n "$DRY" ]; then
        printf 'DRY:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

# 允许失败的 run（例如 launchctl 在某些系统上返回非 0）
run_ignore() {
    run_soft "$@" || true
}

need_root() {
    [ "$(id -u)" = 0 ] || die "需要管理员权限，请通过 app 或 sudo 运行"
}

# --dry-run 只打印、不改系统，因此不要求 root。
# 不变量：DRY 下所有写操作必须经由 run/run_soft/run_ignore。
need_root_or_dry() {
    [ -n "$DRY" ] && return 0
    need_root
}

# 队列名：非空、不以 - 开头、只允许 [A-Za-z0-9_-]，最长 127
valid_queue_name() {
    case "$1" in
        ""|-*|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    [ "${#1}" -le 127 ]
}

# 输入 -> device URI。纯主机名/IP 补 socket:// 与 :9100；带 scheme 只接受 socket://
to_uri() {
    local rest port
    case "$1" in
        *://*)
            case "$1" in
                socket://*) rest=${1#socket://} ;;
                *) return 1 ;;
            esac
            ;;
        *) rest=$1 ;;
    esac
    case "$rest" in
        ""|-*|:*|*:|*[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    case "$rest" in
        *:*)
            port=${rest##*:}
            case "$port" in ""|*[!0-9]*) return 1 ;; esac
            printf 'socket://%s' "$rest" ;;
        *)  printf 'socket://%s:%s' "$rest" "$DEFAULT_PORT" ;;
    esac
}

usage() {
    cat <<'EOF'
用法：
  estudioctl.sh status
  estudioctl.sh install-driver
  estudioctl.sh uninstall-driver [--remove-queues]
  estudioctl.sh list
  estudioctl.sh add NAME IP [--default] [--test]
  estudioctl.sh set-port NAME IP
  estudioctl.sh testpage NAME
  estudioctl.sh remove NAME

全局选项：--dry-run（只打印将执行的命令）
EOF
}

cmd_status() {
    if [ -f "$FILTER_DST" ] && [ -f "$PPD_DST" ]; then
        echo "installed"
    else
        echo "not-installed"
    fi
}

# 输出：队列名<TAB>device URI（只列 PPD 指向本驱动 filter 的队列）
cmd_list() {
    local line name uri ppd out
    if ! out=$(lpstat -v 2>/dev/null); then
        # CUPS 在没有队列时 lpstat -v 返回 1；用 lpstat -r 区分“无队列”与“服务没起来”
        if lpstat -r >/dev/null 2>&1; then
            return 0
        fi
        printf '错误: 无法连接 CUPS，请确认打印服务正在运行\n' >&2
        return 1
    fi
    printf '%s\n' "$out" | while IFS= read -r line; do
        case "$line" in
            "device for "*": "*) ;;
            *) continue ;;
        esac
        name=${line#device for }
        name=${name%%:*}
        uri=${line#*: }
        ppd="$CUPS_PPD_DIR/$name.ppd"
        # 只认独立的 /rastertoestudio，避免 notrastertoestudio 之类误匹配
        if [ -f "$ppd" ] &&
           grep -Eq '(^|[[:space:]/])rastertoestudio([[:space:]"]|$)' "$ppd" 2>/dev/null; then
            printf '%s\t%s\n' "$name" "$uri"
        fi
    done
}

cmd_install_driver() {
    need_root_or_dry
    [ -f "$FILTER_SRC" ] || die "找不到 filter：$FILTER_SRC（先在仓库根运行 make）"
    [ -f "$PPD_SRC" ] || die "找不到 PPD：$PPD_SRC"
    run install -d "$FILTER_DIR"
    run install -m 755 "$FILTER_SRC" "$FILTER_DST"
    run chown root:wheel "$FILTER_DST"
    run chmod 755 "$FILTER_DST"
    run install -d "$PPD_DIR"
    run install -m 644 "$PPD_SRC" "$PPD_DST"
    run chown root:wheel "$PPD_DST"
    run_ignore launchctl kickstart -k system/org.cups.cupsd
    echo "驱动已安装：$FILTER_DST, $PPD_DST"
}

cmd_uninstall_driver() {
    local remove_queues="$1"
    local failed=0 name uri queues

    need_root_or_dry

    # 先删队列再删驱动文件：即使删队列失败，也不会留下“驱动没了、队列还在”的死队列
    if [ "$remove_queues" = "yes" ]; then
        queues=$(cmd_list) || die "无法列出打印机，已中止（未删除任何内容）"
        while IFS=$'\t' read -r name uri; do
            [ -n "$name" ] || continue
            if ! run_soft lpadmin -x "$name"; then
                printf '警告: 删除队列失败：%s\n' "$name" >&2
                failed=$((failed + 1))
            fi
        done <<< "$queues"
    fi

    run rm -f "$FILTER_DST" "$PPD_DST"
    run_ignore launchctl kickstart -k system/org.cups.cupsd

    if [ "$failed" -gt 0 ]; then
        printf '驱动已卸载，但有 %d 个队列未能删除，请手动检查\n' "$failed" >&2
        return 1
    fi
    echo "驱动已卸载"
}

main() {
    # --dry-run 可出现在任意位置：先统一取出，再解析子命令
    local args=() a
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY=1 ;;
            *) args[${#args[@]}]="$a" ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    local cmd="${1:-}"
    if [ $# -gt 0 ]; then shift; fi

    case "$cmd" in
        status)
            [ $# -eq 0 ] || die "status 不接受参数：$*"
            cmd_status ;;
        list)
            [ $# -eq 0 ] || die "list 不接受参数：$*"
            cmd_list ;;
        install-driver)
            [ $# -eq 0 ] || die "install-driver 不接受参数：$*"
            cmd_install_driver ;;
        uninstall-driver)
            local rq=no
            case "${1:-}" in
                "") ;;
                --remove-queues) rq=yes ;;
                *) die "未知选项：$1" ;;
            esac
            [ $# -le 1 ] || die "uninstall-driver 最多接受一个选项"
            cmd_uninstall_driver "$rq" ;;
        -h|--help)
            usage; exit 0 ;;
        "")
            usage >&2; exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
}

[ "${ESTUDIO_LIB_ONLY:-}" = 1 ] || main "$@"
