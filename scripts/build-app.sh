#!/bin/bash
#
# build-app.sh — 把 app/main.applescript 打包成「eSTUDIO 打印机管理.app」
#
#   sh scripts/build-app.sh
#
# 产物：app/build/eSTUDIO 打印机管理.app
# 包内布局（estudioctl.sh 会自动识别 Contents/Resources 布局）：
#   Contents/Resources/estudioctl.sh
#   Contents/Resources/rastertoestudio      （filter，安装时由 ctl 复制到系统目录）
#   Contents/Resources/eSTUDIO2823AM.ppd
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/build"
APP="$OUT/eSTUDIO 打印机管理.app"

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

[ -f "$ROOT/app/main.applescript" ] || die "缺少 app/main.applescript"
[ -f "$ROOT/rastertoestudio" ]      || die "缺少 rastertoestudio，请先在仓库根运行 make"

rm -rf "$APP"
mkdir -p "$OUT"

osacompile -o "$APP" "$ROOT/app/main.applescript"

RES="$APP/Contents/Resources"
install -m 755 "$ROOT/scripts/estudioctl.sh" "$RES/estudioctl.sh"
install -m 755 "$ROOT/rastertoestudio"       "$RES/rastertoestudio"
install -m 644 "$ROOT/ppd/eSTUDIO2823AM.ppd" "$RES/eSTUDIO2823AM.ppd"

PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null 2>&1 || true; }
pb "Add :CFBundleName string eSTUDIO 打印机管理"
pb "Set :CFBundleName eSTUDIO 打印机管理"
pb "Add :CFBundleDisplayName string eSTUDIO 打印机管理"
pb "Set :CFBundleDisplayName eSTUDIO 打印机管理"
pb "Add :CFBundleIdentifier string com.estudio.printermanager"
pb "Set :CFBundleIdentifier com.estudio.printermanager"
pb "Add :CFBundleShortVersionString string 1.0"
pb "Add :CFBundleVersion string 1"
pb "Add :NSHighResolutionCapable bool true"
pb "Add :LSMinimumSystemVersion string 11.0"

# 自检：包内的 ctl 必须能认出自带的 filter / PPD（否则 app 里“安装驱动”必然失败）
"$RES/estudioctl.sh" --dry-run install-driver >/dev/null || die "包内 estudioctl.sh 自检失败"
RESOLVED=$(ESTUDIO_LIB_ONLY=1 bash -c '. "$1"; printf "%s\n%s\n" "$FILTER_SRC" "$PPD_SRC"' _ "$RES/estudioctl.sh")
printf '%s\n' "$RESOLVED" | grep -qxF "$RES/rastertoestudio"   || die "包内 ctl 未认出自带 filter"
printf '%s\n' "$RESOLVED" | grep -qxF "$RES/eSTUDIO2823AM.ppd" || die "包内 ctl 未认出自带 PPD"

# ad-hoc 签名（失败不影响使用，只是首次打开可能多一个确认）
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "提示: ad-hoc 签名未完成，首次打开可能需要右键→打开" >&2

echo "已构建：$APP"
