#!/bin/zsh
# 编译 cc-composer，安装到 ~/Applications 并（重新）启动
#   ./build.sh               编译、安装、启动
#   ./build.sh --autostart   同上，另外设成登录后自动启动
#   ./build.sh --no-launch   只编译安装，不启动
# 注意：每次重新编译后签名会变，macOS 会再问一次“是否允许控制 Ghostty”
set -euo pipefail
cd "${0:A:h}"
APP=~/Applications/cc-composer.app
LABEL=io.github.aazzaazzaazzaa.cc-composer
BIN=$(mktemp -d)/cc-composer

swiftc -O -o "$BIN" main.swift -framework Cocoa -framework Carbon -framework Quartz

pkill -x cc-composer 2>/dev/null && sleep 0.5 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mv "$BIN" "$APP/Contents/MacOS/cc-composer"
codesign --force --sign - "$APP"
echo "installed: $APP"

if [[ " $* " == *" --autostart "* ]]; then
  PLIST=~/Library/LaunchAgents/$LABEL.plist
  mkdir -p ~/Library/LaunchAgents
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>$APP</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
  echo "autostart: $PLIST"
fi

[[ " $* " == *" --no-launch "* ]] || open "$APP"
