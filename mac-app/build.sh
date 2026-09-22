#!/bin/zsh
set -e
app_dir="${1:-$PWD/Pocket Clipboard.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc PocketClipboardApp.swift -o "$app_dir/Contents/MacOS/PocketClipboard" -framework Cocoa
cp Info.plist "$app_dir/Contents/Info.plist"
printf '%s\n' "$app_dir"
