#!/bin/bash
#
# checkopts.sh — 校验 PPD 选项 → PJL 行 / 纸张像素尺寸的映射
#
#   ./tools/checkopts.sh [filter] [mkraster]
#
# 用合成 raster 跑一遍 filter，逐条 grep 期望的 PJL 行。
# 期望值来自实体机抓包（23_bin1 / 24_bin2 / 25_bypass / 16-19）和
# eSSh6OCM.dll 的字符串表，不靠猜。
#
set -u

RTE=${1:-./rastertoestudio}
MK=${2:-./tools/mkraster}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/estudio-opts.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

"$MK" "$TMP/t.raster" 800 600 1 >/dev/null || exit 2

fail=0

check() {
    desc=$1
    opts=$2
    shift 2
    if ! "$RTE" 1 u t 1 "$opts" "$TMP/t.raster" >"$TMP/o.prn"; then
        echo "FAIL $desc: filter exited non-zero"
        fail=1
        return
    fi
    for want in "$@"; do
        if ! grep -aqF "$want" "$TMP/o.prn"; then
            echo "FAIL $desc: missing '$want'"
            fail=1
        fi
    done
    echo "ok   $desc"
}

check "A4 / 纸盒2 / 厚纸 / 省墨 / 平滑" \
    "PageSize=A4 InputSlot=Tray2 MediaType=Thick TonerSave=True Smoothing=True" \
    "@PJL SET PAPER=A4" "@PJL SET PAPERWIDTH=4961" "@PJL SET PAPERLENGTH=7016" \
    "@PJL SET MEDIASOURCE=TRAY2" "@PJL SET MEDIATYPE=THICK" \
    "@PJL SET TONERSAVE=ON" "@PJL SET SMOOTHING=ON"

check "Letter / 旁路 / 信封" \
    "PageSize=Letter InputSlot=Bypass MediaType=Envelope" \
    "@PJL SET PAPER=LETTER" "@PJL SET PAPERWIDTH=5100" "@PJL SET PAPERLENGTH=6600" \
    "@PJL SET MEDIASOURCE=MANUALFEED" "@PJL SET MEDIATYPE=ENVELOPE"

# 2323AM/2823AM 无自动双面单元：即使上游塞进 Duplex 选项，也必须始终单面、不发 BINDING
"$RTE" 1 u t 1 "PageSize=A4 Duplex=DuplexNoTumble" "$TMP/t.raster" >"$TMP/d.prn" || fail=1
if grep -aqF "@PJL SET DUPLEX=OFF" "$TMP/d.prn" && ! grep -aqF "BINDING" "$TMP/d.prn"; then
    echo "ok   双面选项被忽略：始终 DUPLEX=OFF、无 BINDING"
else
    echo "FAIL 双面选项未被忽略"
    fail=1
fi

check "A3 / 纸盒1 / 透明胶片" \
    "PageSize=A3 InputSlot=Tray1 MediaType=Transparency" \
    "@PJL SET PAPER=A3" "@PJL SET PAPERWIDTH=7016" "@PJL SET PAPERLENGTH=9921" \
    "@PJL SET MEDIASOURCE=TRAY1" "@PJL SET MEDIATYPE=TRANSPARENCY"

check "A5 / 自动 / 再生纸" \
    "PageSize=A5 MediaType=Recycle" \
    "@PJL SET PAPER=A5" "@PJL SET PAPERWIDTH=3496" "@PJL SET PAPERLENGTH=4961" \
    "@PJL SET MEDIASOURCE=AUTO" "@PJL SET MEDIATYPE=RECYCLE"

check "Tabloid -> LEDGER" "PageSize=Tabloid" \
    "@PJL SET PAPER=LEDGER" "@PJL SET PAPERWIDTH=6600" "@PJL SET PAPERLENGTH=10200"

check "FanFoldGermanLegal -> 13LG" "PageSize=FanFoldGermanLegal" \
    "@PJL SET PAPER=13LG" "@PJL SET PAPERWIDTH=5100" "@PJL SET PAPERLENGTH=7800"

check "Postcard -> JPOST" "PageSize=Postcard" \
    "@PJL SET PAPER=JPOST" "@PJL SET PAPERWIDTH=2362" "@PJL SET PAPERLENGTH=3496"

check "8.5x8.5 -> 85SQ" "PageSize=8.5x8.5" \
    "@PJL SET PAPER=85SQ" "@PJL SET PAPERWIDTH=5100" "@PJL SET PAPERLENGTH=5105"

check "横向 orientation-requested=4" "PageSize=A4 orientation-requested=4" \
    "@PJL SET ORIENTATION=LANDSCAPE"

check "纵向默认" "PageSize=A4" "@PJL SET ORIENTATION=PORTRAIT"

# 多份：整份作业重复 N 次，2×COPYEND + 1×EOJ，COPIES 恒为 1
"$RTE" 1 u t 3 "PageSize=A4" "$TMP/t.raster" >"$TMP/c.prn" || fail=1
n_start=$(grep -acF "@PJL SET PAGESTATUS=START" "$TMP/c.prn")
n_copyend=$(grep -acF "@PJL COPYEND" "$TMP/c.prn")
n_eoj=$(grep -acF "@PJL EOJ" "$TMP/c.prn")
n_stamp=$(grep -acF "@PJL SET TIMESTAMP=" "$TMP/c.prn")
if [ "$n_start" = 3 ] && [ "$n_copyend" = 2 ] && [ "$n_eoj" = 1 ] && [ "$n_stamp" = 1 ]; then
    echo "ok   3 份：3 页 / 2 COPYEND / 1 EOJ / 1 TIMESTAMP"
else
    echo "FAIL 3 份：pages=$n_start copyend=$n_copyend eoj=$n_eoj timestamp=$n_stamp"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "选项映射检查失败"
    exit 1
fi
echo "选项映射：全部通过"
