#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
swift build -c release --product Lynt
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_PATH="$PROJECT_ROOT/build/Lynt.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/Lynt" "$APP_PATH/Contents/MacOS/Lynt"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.lynt.personal-writing-assistant "$APP_PATH"
print -r -- "Built: $APP_PATH"
print -r -- "Launch: open '$APP_PATH'"
