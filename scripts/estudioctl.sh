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

cmd_install_driver() {
    [ -n "$DRY" ] || need_root
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
    [ -n "$DRY" ] || need_root
    run rm -f "$FILTER_DST" "$PPD_DST"
    if [ "$remove_queues" = "yes" ]; then
        local name uri
        while IFS=$'\t' read -r name uri; do
            [ -n "$name" ] || continue
            run lpadmin -x "$name"
        done < <(cmd_list)
    fi
    run_ignore launchctl kickstart -k system/org.cups.cupsd
    echo "驱动已卸载"
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
        list)           cmd_list ;;
        install-driver) cmd_install_driver ;;
        uninstall-driver)
            local rq=no
            [ "${1:-}" = "--remove-queues" ] && rq=yes
            cmd_uninstall_driver "$rq" ;;
        -h|--help)
            usage; exit 0 ;;
        "")
            usage >&2; exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
}

[ "${ESTUDIO_LIB_ONLY:-}" = 1 ] || main "$@"
