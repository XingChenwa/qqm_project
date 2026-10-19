#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'IPA 编译需要 macOS/Xcode；Windows 请使用 GitHub 的“移动端与 macOS 安装包”工作流。' >&2
  exit 1
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
command -v flutter >/dev/null
xcodebuild -version

# 实际编译真机 arm64 程序；失败即退出，不能仅压缩源代码伪装成 IPA。
update_args=()
if [[ -n "${UPDATE_PUBLIC_KEY:-}" ]]; then
  update_args+=("--dart-define=UPDATE_PUBLIC_KEY=$UPDATE_PUBLIC_KEY")
  update_args+=("--dart-define=UPDATE_BASE_URL=${UPDATE_BASE_URL:-https://xingchenwa.github.io/qqm_project}")
fi
update_args+=("--dart-define=UPDATE_CHANNEL=${UPDATE_CHANNEL:-}")
flutter build ios --release --no-codesign --no-pub --build-name="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' pubspec.yaml)" "${update_args[@]}"
app_path="$project_dir/build/ios/iphoneos/Runner.app"
test -f "$app_path/Runner"
lipo -archs "$app_path/Runner" | grep -q arm64

package_dir="$(mktemp -d "${TMPDIR:-/tmp}/qqm-unsigned-ipa.XXXXXX")"
cleanup() {
  # 仅清理本次 mktemp 创建的目录。
  if [[ -d "$package_dir" && "$package_dir" == *'/qqm-unsigned-ipa.'* ]]; then
    rm -rf -- "$package_dir"
  fi
}
trap cleanup EXIT
mkdir -p "$package_dir/Payload" "$project_dir/dist"
ditto "$app_path" "$package_dir/Payload/Runner.app"
ipa="$project_dir/dist/$(node tool/package_names.mjs ios_file)"
if [[ -e "$ipa" ]]; then
  printf '%s\n' '安装包已存在，请使用干净的构建目录。' >&2
  exit 1
fi
ditto -c -k --norsrc --keepParent "$package_dir/Payload" "$ipa"
unzip -l "$ipa" | tail -n 3
printf '已生成 %s。此包尚未签名，不能直接安装。\n' "$ipa"
