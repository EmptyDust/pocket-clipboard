#!/bin/zsh
set -e
app_dir="${1:-$PWD/Pocket Clipboard.app}"
cd "${0:A:h}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -O RelayClient.swift PocketClipboardApp.swift main.swift -o "$app_dir/Contents/MacOS/PocketClipboard" -framework Cocoa
cp Info.plist "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
printf '%s\n' "$app_dir"
