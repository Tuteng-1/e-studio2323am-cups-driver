#!/bin/bash
#
# e-STUDIO2323AM / 2823AM 原生 CUPS 驱动安装脚本
#
#   sudo ./scripts/install.sh                      # 只安装 filter + PPD
#   sudo ./scripts/install.sh --queue 192.0.2.10  # 同时建网络队列（socket://IP:9100）
#   sudo ./scripts/install.sh --queue socket://192.0.2.10:9100
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER_DIR=/usr/libexec/cups/filter
PPD_DIR=/Library/Printers/PPDs/Contents/Resources

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

echo "== 安装 filter =="
install -d "$FILTER_DIR"
install -m 755 "$ROOT/rastertoestudio" "$FILTER_DIR/rastertoestudio"
# CUPS 沙箱要求 root:wheel 且 755
chown root:wheel "$FILTER_DIR/rastertoestudio"
chmod 755 "$FILTER_DIR/rastertoestudio"

echo "== 安装 PPD =="
install -d "$PPD_DIR"
install -m 644 "$ROOT/ppd/eSTUDIO2823AM.ppd" "$PPD_DIR/eSTUDIO2823AM.ppd"
chown root:wheel "$PPD_DIR/eSTUDIO2823AM.ppd"

echo "== 重启 cupsd =="
launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null || true
sleep 1

if [ -n "$QUEUE_ADDR" ]; then
    case "$QUEUE_ADDR" in
        *://*) URI="$QUEUE_ADDR" ;;
        *)     URI="socket://$QUEUE_ADDR:9100" ;;
    esac

    echo "== 创建队列 eSTUDIO2823AM -> $URI =="
    lpadmin -p eSTUDIO2823AM -E -v "$URI" \
            -P "$PPD_DIR/eSTUDIO2823AM.ppd" -o printer-is-shared=false
    lpadmin -d eSTUDIO2823AM

    if [ "$(lpstat -p eSTUDIO2823AM 2>/dev/null | grep -c disabled)" = "0" ]; then
        echo "队列已创建。测试：lp -d eSTUDIO2823AM /etc/hosts"
    else
        echo "警告：队列处于 disabled 状态，检查 lpstat -p eSTUDIO2823AM"
    fi
else
    cat <<EOF

安装完成。手动添加队列：

  sudo lpadmin -p eSTUDIO2823AM -E -v socket://<打印机IP>:9100 \\
       -P $PPD_DIR/eSTUDIO2823AM.ppd

USB 连接请先用 system_profiler SPUSBDataType 确认厂商/产品 ID，
再用 ipp-usb 或 usb://TOSHIBA/e-STUDIO2823AM 形式。
EOF
fi
