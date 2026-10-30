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

# 用 BASH_SOURCE 而不是 $0：这样被 source（lib 模式）时也能定位到自身
SELF_PATH="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SELF_PATH")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FILTER_REL=rastertoestudio
PPD_REL=ppd/eSTUDIO2823AM.ppd
# app 包内布局：ctl 在 Contents/Resources，filter 与 PPD 就放在同一目录
case "$HERE" in
    */Contents/Resources) ROOT="$HERE"; PPD_REL=eSTUDIO2823AM.ppd ;;
esac

FILTER_SRC="${ESTUDIO_FILTER_SRC:-$ROOT/$FILTER_REL}"
PPD_SRC="${ESTUDIO_PPD_SRC:-$ROOT/$PPD_REL}"

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

cmd_testpage() {
    local name="$1"
    valid_queue_name "$name" || die "非法队列名：$name"
    need_root_or_dry
    run lp -d "$name" /etc/hosts
    echo "测试页已发送：$name"
}

cmd_add() {
    local name="$1" target="$2" make_default="$3" do_test="$4" uri
    valid_queue_name "$name" || die "非法队列名：$name（只允许字母数字 _ -）"
    uri=$(to_uri "$target") || die "非法地址：$target"
    [ -f "$PPD_DST" ] || die "驱动尚未安装，请先安装驱动"
    need_root_or_dry
    run lpadmin -p "$name" -E -v "$uri" -P "$PPD_DST" -o printer-is-shared=false
    if [ "$make_default" = "yes" ]; then
        run lpadmin -d "$name"
    fi
    echo "已添加打印机：$name -> $uri"
    if [ "$do_test" = "yes" ]; then
        cmd_testpage "$name"
    fi
}

cmd_set_port() {
    local name="$1" target="$2" uri
    valid_queue_name "$name" || die "非法队列名：$name"
    uri=$(to_uri "$target") || die "非法地址：$target"
    need_root_or_dry
    run lpadmin -p "$name" -v "$uri"
    echo "端口已更新：$name -> $uri"
}

cmd_remove() {
    local name="$1"
    valid_queue_name "$name" || die "非法队列名：$name"
    need_root_or_dry
    # 幂等：队列可能已被手动删除，此时仍要清掉残留的 PPD 配置
    if ! run_soft lpadmin -x "$name"; then
        printf '警告: 队列不存在或删除失败，继续清理配置：%s\n' "$name" >&2
    fi
    run rm -f "$CUPS_PPD_DIR/$name.ppd"
    echo "已删除打印机：$name"
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
        add)
            [ $# -ge 2 ] || die "用法：add NAME IP [--default] [--test]"
            local aname="$1" atarget="$2" md=no dt=no
            shift 2
            while [ $# -gt 0 ]; do
                case "$1" in
                    --default) md=yes ;;
                    --test)    dt=yes ;;
                    *) die "未知选项：$1" ;;
                esac
                shift
            done
            cmd_add "$aname" "$atarget" "$md" "$dt" ;;
        testpage)
            [ $# -eq 1 ] || die "用法：testpage NAME"
            cmd_testpage "$1" ;;
        set-port)
            [ $# -eq 2 ] || die "用法：set-port NAME IP"
            cmd_set_port "$1" "$2" ;;
        remove)
            [ $# -eq 1 ] || die "用法：remove NAME"
            cmd_remove "$1" ;;
        -h|--help)
            usage; exit 0 ;;
        "")
            usage >&2; exit 1 ;;
        *) die "未知子命令：$cmd" ;;
    esac
}

[ "${ESTUDIO_LIB_ONLY:-}" = 1 ] || main "$@"
