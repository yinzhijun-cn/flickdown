#!/bin/bash
# 在独立目录生成一份 Release 的 ZIP 和签名更新清单。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SPARKLE_PRIVATE_ED_KEY:?请配置仓库密钥 SPARKLE_PRIVATE_ED_KEY}"
release_dir="${1:?请传入新的输出目录}"
download_prefix="${2:?请传入该 tag 的 Release 下载地址}"
app=build/Flickdown.app
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
archive="$release_dir/Flickdown-$version.zip"
feed="$release_dir/appcast.xml"
sparkle_bin=.build/artifacts/sparkle/Sparkle/bin

mkdir "$release_dir"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle_bin/generate_appcast" \
  --ed-key-file - --download-url-prefix "$download_prefix" "$release_dir"

# 公私钥不匹配时 generate_appcast 可能只给出警告，缺少归档签名的版本不能发布。
signature=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$feed")
: "${signature:?归档没有更新签名，请核对应用公钥和发布私钥}"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle_bin/sign_update" --ed-key-file - --verify "$archive" "$signature"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle_bin/sign_update" --ed-key-file - --verify "$feed"
