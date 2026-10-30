#!/bin/bash
#
# e-STUDIO2323AM / 2823AM 原生 CUPS 驱动安装脚本
# （estudioctl.sh 的薄封装：安装逻辑只有一份，在 estudioctl.sh 里）
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
        --queue)   [ $# -ge 2 ] || { echo "用法：$0 --queue <IP|socket://IP:PORT>"; exit 1; }
                   QUEUE_ADDR="$2"; shift 2 ;;
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

echo "== 安装驱动（filter + PPD）=="
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

安装完成。添加队列（也可以直接用「eSTUDIO 打印机管理.app」）：

  sudo "$CTL" add eSTUDIO2823AM <打印机IP> --default --test

USB 连接请先用 system_profiler SPUSBDataType 确认厂商/产品 ID，
再用 ipp-usb 或 usb://TOSHIBA/e-STUDIO2823AM 形式。
EOF
fi
