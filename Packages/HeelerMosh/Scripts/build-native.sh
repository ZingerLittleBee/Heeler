#!/bin/bash

# Assembles the HeelerMosh native artifact from the mosh-spike build products
# (ADR 0011 vendoring pattern: per-slice static archives merged into one
# xcframework committed under Artifacts/).
#
# Why a single merged archive: libmoshios references protobuf symbols but
# protobuf is NOT baked into libmoshios.a. Linking two separate static
# archives through Xcode would make the final link depend on archive
# ordering, so this script merges libmoshios + libprotobuf 2.6.1 per slice
# with libtool(1) and repacks the original framework skeleton. One archive,
# no ordering hazard.
#
# Inputs (from ~/src/mosh-spike, override with HEELER_MOSH_SPIKE_DIR):
#   libmoshios.xcframework  — arm64 device + arm64 simulator slices
#   deps/libprotobuf-device-arm64.a
#   deps/libprotobuf-simulator-arm64.a
#
# Output: Artifacts/libmoshios.xcframework (module name unchanged), plus
# PROVENANCE.md and SHA256SUMS next to it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPIKE_DIR="${HEELER_MOSH_SPIKE_DIR:-${HOME}/src/mosh-spike}"
ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"

for command in libtool xcodebuild xcrun shasum; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "error: required command not found: ${command}" >&2
        exit 1
    }
done

MOSH_XCFRAMEWORK="${SPIKE_DIR}/libmoshios.xcframework"
PROTOBUF_DEVICE="${SPIKE_DIR}/deps/libprotobuf-device-arm64.a"
PROTOBUF_SIMULATOR="${SPIKE_DIR}/deps/libprotobuf-simulator-arm64.a"

for input in "${MOSH_XCFRAMEWORK}" "${PROTOBUF_DEVICE}" "${PROTOBUF_SIMULATOR}"; do
    [[ -e "${input}" ]] || {
        echo "error: missing mosh-spike artifact: ${input}" >&2
        echo "       build the spike first (see its BRIDGE_API.md)." >&2
        exit 1
    }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heeler-mosh-native.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

FRAMEWORKS="${WORK_DIR}/Frameworks"

# Repacks one framework slice with protobuf merged into its static archive.
# $1 = slice platform dir inside the xcframework (ios-arm64 / ios-arm64-simulator)
# $2 = protobuf archive for that slice
# $3 = destination framework directory
# $4 = CFBundleSupportedPlatforms entry (iPhoneOS / iPhoneSimulator)
merge_slice() {
    local slice="$1" protobuf="$2" destination="$3" platform="$4"
    local source="${MOSH_XCFRAMEWORK}/${slice}/libmoshios.framework"

    mkdir -p "${destination}"
    cp -R "${source}/Headers" "${destination}/Headers"
    mkdir -p "${destination}/Modules"

    # Complete framework metadata: CFBundleExecutable is required by the
    # simulator installer, and the SupportedPlatforms entry keeps the
    # embed/sign stages happy (same shape HeelerSSH ships).
    cat > "${destination}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>libmoshios</string>
	<key>CFBundleIdentifier</key><string>com.otreva.heeler.libmoshios</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>libmoshios</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.3.2</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${platform}</string>
	</array>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>18.0</string>
</dict>
</plist>
EOF

    # The spike's module map declares a plain module; Xcode's framework
    # copy requires the `framework` qualifier (same shape HeelerSSH ships).
    cat > "${destination}/Modules/module.modulemap" <<'EOF'
framework module libmoshios [system] {
    umbrella header "moshiosbridge.h"
    export *
}
EOF

    libtool -static -o "${destination}/libmoshios" \
        "${source}/libmoshios" "${protobuf}"
}

merge_slice ios-arm64 "${PROTOBUF_DEVICE}" \
    "${FRAMEWORKS}/device/libmoshios.framework" iPhoneOS
merge_slice ios-arm64-simulator "${PROTOBUF_SIMULATOR}" \
    "${FRAMEWORKS}/simulator/libmoshios.framework" iPhoneSimulator

# Sanity: the merged device archive must still export the bridge symbol and
# pull in protobuf (checked via a mangled protobuf symbol).
for framework in "${FRAMEWORKS}/device/libmoshios.framework" \
    "${FRAMEWORKS}/simulator/libmoshios.framework"; do
    nm -gU "${framework}/libmoshios" | grep "_mosh_main" >/dev/null || {
        echo "error: _mosh_main missing from $(dirname "${framework}")" >&2
        exit 1
    }
    nm "${framework}/libmoshios" | grep "6google8protobuf" >/dev/null || {
        echo "error: protobuf symbols missing from $(dirname "${framework}")" >&2
        exit 1
    }
done

GENERATED="${WORK_DIR}/Artifacts"
mkdir -p "${GENERATED}"
xcodebuild -create-xcframework \
    -framework "${FRAMEWORKS}/device/libmoshios.framework" \
    -framework "${FRAMEWORKS}/simulator/libmoshios.framework" \
    -output "${GENERATED}/libmoshios.xcframework"

XCODE_VERSION="$(xcodebuild -version | paste -sd ';' -)"
SPIKE_MOSH_HASH="$(shasum -a 256 "${MOSH_XCFRAMEWORK}/ios-arm64/libmoshios.framework/libmoshios" | cut -d ' ' -f 1)"
cat > "${GENERATED}/PROVENANCE.md" <<EOF
# Native artifact provenance

- Source: mosh (Blink iOS port) + protobuf 2.6.1, built in \`~/src/mosh-spike\`
  (\`build-all.sh\`; patches recorded in the spike's \`patches/\`).
- Spike mosh device-slice archive SHA-256: \`${SPIKE_MOSH_HASH}\`
- Assembled by \`Scripts/build-native.sh\`: libtool-merged
  libmoshios + libprotobuf per slice, repacked into the original framework
  skeleton, combined with \`xcodebuild -create-xcframework\`.
- Slices: arm64 (iPhoneOS) + arm64 (iPhoneSimulator), MinimumOSVersion 18.0.
- Xcode: \`${XCODE_VERSION}\`
- Link requirements surfaced to the consumer: \`-lc++ -lz\` (libc++ and zlib;
  everything else is system). CommonCrypto-backed, no OpenSSL dependency.
EOF

(
    cd "${GENERATED}"
    shasum -a 256 libmoshios.xcframework/ios-arm64/libmoshios.framework/libmoshios \
        libmoshios.xcframework/ios-arm64-simulator/libmoshios.framework/libmoshios \
        > SHA256SUMS
)

rm -rf "${ARTIFACT_DIR}/libmoshios.xcframework"
cp -R "${GENERATED}/libmoshios.xcframework" "${ARTIFACT_DIR}/libmoshios.xcframework"
cp "${GENERATED}/PROVENANCE.md" "${GENERATED}/SHA256SUMS" "${ARTIFACT_DIR}/"

echo "Assembled ${ARTIFACT_DIR}/libmoshios.xcframework"
