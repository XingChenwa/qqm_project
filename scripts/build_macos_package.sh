#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'macOS 应用必须在 macOS/Xcode 上构建，请使用 GitHub 云端构建。' >&2
  exit 1
fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
update_args=()
if [[ -n "${UPDATE_PUBLIC_KEY:-}" ]]; then
  update_args+=("--dart-define=UPDATE_PUBLIC_KEY=$UPDATE_PUBLIC_KEY")
  update_args+=("--dart-define=UPDATE_BASE_URL=${UPDATE_BASE_URL:-https://botmanager.uuze.cn}")
fi
flutter build macos --release --no-pub "${update_args[@]}"
app_path="$project_dir/build/macos/Build/Products/Release/QQBotManager.app"
binary="$app_path/Contents/MacOS/QQBotManager"
test -f "$binary"
lipo -verify_arch arm64 x86_64 "$binary"
codesign --verify --deep --strict "$app_path"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" = cn.uuze.botmanager

mkdir -p "$project_dir/dist"
dmg="$project_dir/dist/qqbotmanager-macos-universal.dmg"
archive="$project_dir/dist/qqbotmanager-macos-universal.zip"
if [[ -e "$dmg" || -e "$archive" ]]; then
  printf '%s\n' '安装包已存在，请保留旧产物并使用干净的构建目录。' >&2
  exit 1
fi
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/qqm-macos-package.XXXXXX")"
cleanup() {
  if [[ -d "$package_dir" && "$package_dir" == *'/qqm-macos-package.'* ]]; then
    rm -rf -- "$package_dir"
  fi
}
trap cleanup EXIT
ditto "$app_path" "$package_dir/QQBotManager.app"
ln -s /Applications "$package_dir/Applications"
hdiutil create -volname 'QQ机器人管理器' -srcfolder "$package_dir" -format UDZO "$dmg"
hdiutil verify "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
shasum -a 256 "$dmg" "$archive"
printf '%s\n' '已生成 Universal DMG 和 ZIP。当前为 ad-hoc 临时签名，未经过 Developer ID 签名或 Apple 公证。'
