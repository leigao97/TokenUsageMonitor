#!/bin/bash
# Build TokenUsageMonitor.app, install it to /Applications and launch it.
#   ./build.sh            build + install + launch
#   ./build.sh --no-install   build only (output: .build/TokenUsageMonitor.app)
set -euo pipefail
cd "$(dirname "$0")"

APP="TokenUsageMonitor.app"
DEST="/Applications/${APP}"

echo "==> Building"
swift build -c release

echo "==> Rendering icon"
rm -rf .build/AppIcon.iconset
swift scripts/make_icon.swift .build/AppIcon.iconset >/dev/null
iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns

echo "==> Packaging ${APP}"
rm -rf ".build/${APP}"
mkdir -p ".build/${APP}/Contents/MacOS" ".build/${APP}/Contents/Resources"
cp .build/release/TokenUsageMonitor ".build/${APP}/Contents/MacOS/TokenUsageMonitor"
cp .build/AppIcon.icns ".build/${APP}/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist ".build/${APP}/Contents/Info.plist"
codesign --force --deep -s - ".build/${APP}" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built .build/${APP}"
  exit 0
fi

echo "==> Installing to ${DEST}"
pkill -x TokenUsageMonitor 2>/dev/null || true
rm -rf "${HOME}/Applications/${APP}"
rm -rf "${DEST}"
cp -R ".build/${APP}" "${DEST}"
open "${DEST}"
echo "Done. Look for the ring icon in your menu bar."
