#!/bin/bash
set -euo pipefail

VERSION="26.9.9"
GEO_VERSION="202610082207"
GEOIP_SHA256="116cc0f03d48991962f7f9cdbbcf53d45d89777f9c3cd1a663210853e5df6093"
GEOSITE_SHA256="cc5f00ba417ee56daea66d160e8cf8704fbfb2a6af8ae27fd64017cb1ebcf034"

case "${ARCHS:-$(uname -m)}" in
    *arm64*)
        coreArch="arm64"
        archName="arm64-v8a"
        coreSHA256="7616e4d8d5b8bedaee14ebe167954e24f35ccea58cdb941600e2ff76509fc31c"
        ;;
    *x86_64*)
        coreArch="x86_64"
        archName="64"
        coreSHA256="dc7af506e28dd45fa2847841517674f0a0c5af8827d8ac40d1aa9615267e3a78"
        ;;
    *)
        echo "Unsupported Xray architecture: ${ARCHS:-$(uname -m)}" >&2
        exit 1
        ;;
esac

cd "$SRCROOT"

checksumMatches() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]]
}

if checksumMatches xray-core-bin/xray "$coreSHA256" &&
   checksumMatches xray-core-bin/geoip.dat "$GEOIP_SHA256" &&
   checksumMatches xray-core-bin/geosite.dat "$GEOSITE_SHA256"; then
    exit 0
fi

staging=$(mktemp -d "$SRCROOT/xray-core-bin.XXXXXX")
trap 'rm -rf "$staging"' EXIT

download() {
    curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"
}

verify() {
    if ! checksumMatches "$1" "$2"; then
        echo "Checksum mismatch: $1" >&2
        exit 1
    fi
}

echo "Downloading Xray $VERSION ($coreArch) and Loyalsoldier geo files $GEO_VERSION"
download "https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-macos-${archName}.zip" "$staging/xray.zip"
unzip -q -j "$staging/xray.zip" xray -d "$staging"
verify "$staging/xray" "$coreSHA256"
chmod +x "$staging/xray"

geoURL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$GEO_VERSION"
download "$geoURL/geoip.dat" "$staging/geoip.dat"
download "$geoURL/geosite.dat" "$staging/geosite.dat"
verify "$staging/geoip.dat" "$GEOIP_SHA256"
verify "$staging/geosite.dat" "$GEOSITE_SHA256"

rm -f "$staging/xray.zip"
rm -rf xray-core-bin
mv "$staging" xray-core-bin
