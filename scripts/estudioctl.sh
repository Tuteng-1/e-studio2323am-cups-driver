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
        return 0
    fi
    "$@" || die "命令失败（退出码 $?）：$*"
}

# 允许失败的 run（例如 launchctl 在某些系统上返回非 0）
run_ignore() {
    if [ -n "$DRY" ]; then
        printf 'DRY:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@" || true
}

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" = 0 ] || die "需要管理员权限，请通过 app 或 sudo 运行"
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
        status)
            [ $# -eq 0 ] || die "status 不接受参数：$*"
            cmd_status ;;
        -h|--help)
            usage; exit 0 ;;
        "")
            usage >&2; exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
}

[ "${ESTUDIO_LIB_ONLY:-}" = 1 ] || main "$@"
