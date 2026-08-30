#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_LOCK="${HEELER_SSH_SOURCE_LOCK:-${PACKAGE_DIR}/Sources.lock}"
DEPLOYMENT_TARGET="18.0"
FIXED_PREFIX="/usr/local/heeler-ssh/openssl-3.6.3"
JOBS="${HEELER_SSH_JOBS:-4}"
XCFRAMEWORK_SIGNING_IDENTITY="${HEELER_SSH_XCFRAMEWORK_SIGNING_IDENTITY:-}"

# shellcheck source=../Sources.lock
source "${SOURCE_LOCK}"

for command in curl shasum tar perl make cmake xcodebuild xcrun codesign; do
    command -v "${command}" >/dev/null || {
        echo "error: required command not found: ${command}" >&2
        exit 1
    }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heeler-ssh-native.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

download_and_verify() {
    local name="$1"
    local url="$2"
    local expected_sha256="$3"
    local archive="${WORK_DIR}/${name}.tar.gz"

    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 --retry-all-errors \
        "${url}" --output "${archive}"

    local actual_sha256
    actual_sha256="$(shasum -a 256 "${archive}" | awk '{print $1}')"
    if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
        echo "error: ${name} source hash mismatch" >&2
        echo "expected: ${expected_sha256}" >&2
        echo "actual:   ${actual_sha256}" >&2
        exit 1
    fi

    tar -xzf "${archive}" -C "${WORK_DIR}"
}

download_and_verify "libssh2-${LIBSSH2_VERSION}" "${LIBSSH2_URL}" "${LIBSSH2_SHA256}"
download_and_verify "openssl-${OPENSSL_VERSION}" "${OPENSSL_URL}" "${OPENSSL_SHA256}"

if [[ "${1:-}" == "--verify-sources-only" ]]; then
    echo "Verified libssh2 ${LIBSSH2_VERSION} and OpenSSL ${OPENSSL_VERSION} source archives."
    exit 0
fi

[[ -n "${XCFRAMEWORK_SIGNING_IDENTITY}" ]] || {
    echo "error: HEELER_SSH_XCFRAMEWORK_SIGNING_IDENTITY is required" >&2
    echo "Set it to an Apple Development or Apple Distribution identity." >&2
    exit 1
}

LIBSSH2_SOURCE="${WORK_DIR}/libssh2-${LIBSSH2_VERSION}"
OPENSSL_SOURCE="${WORK_DIR}/openssl-${OPENSSL_VERSION}"

build_openssl() {
    local name="$1"
    local configure_target="$2"
    local minimum_flag="$3"
    local output_variable="$4"
    local build_dir="${WORK_DIR}/openssl-${name}"
    local install_root="${WORK_DIR}/openssl-${name}-install"

    mkdir -p "${build_dir}" "${install_root}"
    (
        cd "${build_dir}"
        env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
            perl "${OPENSSL_SOURCE}/Configure" \
                "${configure_target}" \
                no-shared no-tests no-apps no-docs no-module no-legacy \
                no-dso no-engine no-deprecated no-dsa no-rc2 no-rc4 \
                no-des no-cast no-bf no-idea no-seed no-camellia no-aria \
                no-sm2 no-sm3 no-sm4 no-whirlpool no-rmd160 \
                --prefix="${FIXED_PREFIX}" \
                --openssldir="${FIXED_PREFIX}" \
                --libdir=lib \
                "${minimum_flag}=${DEPLOYMENT_TARGET}"
        make -j"${JOBS}" build_generated libcrypto.a
    )

    local installed_prefix="${install_root}${FIXED_PREFIX}"
    mkdir -p "${installed_prefix}/include/openssl" "${installed_prefix}/lib"
    cp -R "${OPENSSL_SOURCE}/include/openssl/." "${installed_prefix}/include/openssl/"
    cp -R "${build_dir}/include/openssl/." "${installed_prefix}/include/openssl/"
    find "${installed_prefix}/include/openssl" -type f -name '*.in' -delete
    cp "${build_dir}/libcrypto.a" "${installed_prefix}/lib/libcrypto.a"

    printf -v "${output_variable}" '%s' "${installed_prefix}"
}

build_libssh2() {
    local name="$1"
    local sdk="$2"
    local openssl_install="$3"
    local output_variable="$4"
    local build_dir="${WORK_DIR}/libssh2-${name}"
    local install_dir="${WORK_DIR}/libssh2-${name}-install"
    local security_defines
    security_defines="-DLIBSSH2_NO_AES_CBC"

    env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
        cmake -S "${LIBSSH2_SOURCE}" -B "${build_dir}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_SYSROOT="${sdk}" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
            -DCMAKE_INSTALL_PREFIX="${install_dir}" \
            -DCMAKE_C_FLAGS="${security_defines}" \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DBUILD_EXAMPLES=OFF \
            -DBUILD_TESTING=OFF \
            -DENABLE_ZLIB_COMPRESSION=OFF \
            -DENABLE_DEBUG_LOGGING=OFF \
            -DCRYPTO_BACKEND=OpenSSL \
            -DOPENSSL_USE_STATIC_LIBS=TRUE \
            -DOPENSSL_ROOT_DIR="${openssl_install}" \
            -DOPENSSL_INCLUDE_DIR="${openssl_install}/include" \
            -DOPENSSL_CRYPTO_LIBRARY="${openssl_install}/lib/libcrypto.a"
    cmake --build "${build_dir}" --parallel "${JOBS}"
    cmake --install "${build_dir}"

    printf -v "${output_variable}" '%s' "${install_dir}"
}

OPENSSL_DEVICE=""
OPENSSL_SIMULATOR=""
LIBSSH2_DEVICE=""
LIBSSH2_SIMULATOR=""
build_openssl device ios64-xcrun -mios-version-min OPENSSL_DEVICE
build_openssl simulator iossimulator-arm64-xcrun -miphonesimulator-version-min OPENSSL_SIMULATOR
build_libssh2 device iphoneos "${OPENSSL_DEVICE}" LIBSSH2_DEVICE
build_libssh2 simulator iphonesimulator "${OPENSSL_SIMULATOR}" LIBSSH2_SIMULATOR

OPENSSL_DEVICE_HEADERS="${WORK_DIR}/headers-openssl-device"
OPENSSL_SIMULATOR_HEADERS="${WORK_DIR}/headers-openssl-simulator"
LIBSSH2_DEVICE_HEADERS="${WORK_DIR}/headers-libssh2-device"
LIBSSH2_SIMULATOR_HEADERS="${WORK_DIR}/headers-libssh2-simulator"

mkdir -p \
    "${OPENSSL_DEVICE_HEADERS}" "${OPENSSL_SIMULATOR_HEADERS}" \
    "${LIBSSH2_DEVICE_HEADERS}" "${LIBSSH2_SIMULATOR_HEADERS}"
cp -R "${OPENSSL_DEVICE}/include/openssl" "${OPENSSL_DEVICE_HEADERS}/openssl"
cp -R "${OPENSSL_SIMULATOR}/include/openssl" "${OPENSSL_SIMULATOR_HEADERS}/openssl"
cp "${PACKAGE_DIR}/NativeSupport/COpenSSL.h" "${OPENSSL_DEVICE_HEADERS}/COpenSSL.h"
cp "${PACKAGE_DIR}/NativeSupport/COpenSSL.h" "${OPENSSL_SIMULATOR_HEADERS}/COpenSSL.h"
cp "${LIBSSH2_DEVICE}/include/"*.h "${LIBSSH2_DEVICE_HEADERS}/"
cp "${LIBSSH2_SIMULATOR}/include/"*.h "${LIBSSH2_SIMULATOR_HEADERS}/"
cp "${PACKAGE_DIR}/NativeSupport/CLibSSH2.h" "${LIBSSH2_DEVICE_HEADERS}/CLibSSH2.h"
cp "${PACKAGE_DIR}/NativeSupport/CLibSSH2.h" "${LIBSSH2_SIMULATOR_HEADERS}/CLibSSH2.h"

create_static_framework() {
    local name="$1"
    local library="$2"
    local headers="$3"
    local modulemap="$4"
    local platform="$5"
    local output="$6"

    mkdir -p "${output}/Headers" "${output}/Modules"
    cp "${library}" "${output}/${name}"
    cp -R "${headers}/." "${output}/Headers/"
    cp "${modulemap}" "${output}/Modules/module.modulemap"
    cat > "${output}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>dev.bybee.heeler.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>${platform}</string></array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF
}

FRAMEWORKS="${WORK_DIR}/Frameworks"
create_static_framework COpenSSL "${OPENSSL_DEVICE}/lib/libcrypto.a" \
    "${OPENSSL_DEVICE_HEADERS}" "${PACKAGE_DIR}/NativeSupport/COpenSSL.modulemap" \
    iPhoneOS "${FRAMEWORKS}/device/COpenSSL.framework"
create_static_framework COpenSSL "${OPENSSL_SIMULATOR}/lib/libcrypto.a" \
    "${OPENSSL_SIMULATOR_HEADERS}" "${PACKAGE_DIR}/NativeSupport/COpenSSL.modulemap" \
    iPhoneSimulator "${FRAMEWORKS}/simulator/COpenSSL.framework"
create_static_framework CLibSSH2 "${LIBSSH2_DEVICE}/lib/libssh2.a" \
    "${LIBSSH2_DEVICE_HEADERS}" "${PACKAGE_DIR}/NativeSupport/CLibSSH2.modulemap" \
    iPhoneOS "${FRAMEWORKS}/device/CLibSSH2.framework"
create_static_framework CLibSSH2 "${LIBSSH2_SIMULATOR}/lib/libssh2.a" \
    "${LIBSSH2_SIMULATOR_HEADERS}" "${PACKAGE_DIR}/NativeSupport/CLibSSH2.modulemap" \
    iPhoneSimulator "${FRAMEWORKS}/simulator/CLibSSH2.framework"

OPENSSL_PRIVACY_MANIFEST="${OPENSSL_SOURCE}/os-dep/Apple/PrivacyInfo.xcprivacy"
[[ -f "${OPENSSL_PRIVACY_MANIFEST}" ]] || {
    echo "error: OpenSSL ${OPENSSL_VERSION} privacy manifest is missing" >&2
    exit 1
}
cp "${OPENSSL_PRIVACY_MANIFEST}" \
    "${FRAMEWORKS}/device/COpenSSL.framework/PrivacyInfo.xcprivacy"
cp "${OPENSSL_PRIVACY_MANIFEST}" \
    "${FRAMEWORKS}/simulator/COpenSSL.framework/PrivacyInfo.xcprivacy"

GENERATED_ARTIFACTS="${WORK_DIR}/Artifacts"
mkdir -p "${GENERATED_ARTIFACTS}/Notices"
xcodebuild -create-xcframework \
    -framework "${FRAMEWORKS}/device/COpenSSL.framework" \
    -framework "${FRAMEWORKS}/simulator/COpenSSL.framework" \
    -output "${GENERATED_ARTIFACTS}/COpenSSL.xcframework"
xcodebuild -create-xcframework \
    -framework "${FRAMEWORKS}/device/CLibSSH2.framework" \
    -framework "${FRAMEWORKS}/simulator/CLibSSH2.framework" \
    -output "${GENERATED_ARTIFACTS}/CLibSSH2.xcframework"
codesign --timestamp --sign "${XCFRAMEWORK_SIGNING_IDENTITY}" \
    "${GENERATED_ARTIFACTS}/COpenSSL.xcframework"

cp "${LIBSSH2_SOURCE}/COPYING" "${GENERATED_ARTIFACTS}/Notices/libssh2-BSD-3-Clause.txt"
cp "${OPENSSL_SOURCE}/LICENSE.txt" "${GENERATED_ARTIFACTS}/Notices/OpenSSL-Apache-2.0.txt"
# Separately licensed objects inside the pinned libssh2 snapshot (see REUSE
# SPDX tags in the source headers). The app inventory bundles these next to
# COPYING (#161).
extract_c_header_notice() {
    local source_file="$1"
    local destination="$2"
    # Prefer the comment block that carries SPDX-License-Identifier so a
    # leading one-line RCS banner (bcrypt_pbkdf.c) is not captured alone.
    awk '
        /^\/\*/ {
            in_block = 1
            block = $0 ORS
            if ($0 ~ /\*\//) {
                if (block ~ /SPDX-License-Identifier/) { printf "%s", block; exit }
                in_block = 0
                block = ""
            }
            next
        }
        in_block {
            block = block $0 ORS
            if ($0 ~ /\*\//) {
                if (block ~ /SPDX-License-Identifier/) { printf "%s", block; exit }
                in_block = 0
                block = ""
            }
        }
    ' "${source_file}" > "${destination}"
}
extract_c_header_notice \
    "${LIBSSH2_SOURCE}/src/bcrypt_pbkdf.c" \
    "${GENERATED_ARTIFACTS}/Notices/libssh2-bcrypt_pbkdf-MIT.txt"
extract_c_header_notice \
    "${LIBSSH2_SOURCE}/src/cipher-chachapoly.c" \
    "${GENERATED_ARTIFACTS}/Notices/libssh2-cipher-chachapoly-BSD-2-Clause.txt"

XCODE_VERSION="$(xcodebuild -version | paste -sd ';' -)"
CLANG_VERSION="$(xcrun clang --version | sed -n '1p')"
IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
cat > "${GENERATED_ARTIFACTS}/PROVENANCE.md" <<EOF
# Native artifact provenance

- libssh2: ${LIBSSH2_VERSION}, tag ${LIBSSH2_TAG}, commit ${LIBSSH2_COMMIT}
- OpenSSL: ${OPENSSL_VERSION}, tag ${OPENSSL_TAG}, commit ${OPENSSL_COMMIT}
- Xcode: ${XCODE_VERSION}
- Compiler: ${CLANG_VERSION}
- iPhoneOS SDK: ${IPHONEOS_SDK}
- iPhone Simulator SDK: ${SIMULATOR_SDK}
- Deployment target: iOS ${DEPLOYMENT_TARGET}
- Configuration: Release, static libraries, arm64 device and arm64 Simulator
- OpenSSL features: no shared library, module, legacy provider, deprecated API, DSA, RC2, RC4, DES, CAST, Blowfish, IDEA, SEED, Camellia, ARIA, SM2, SM3, SM4, Whirlpool, or RIPEMD-160
- OpenSSL privacy manifest: upstream os-dep/Apple/PrivacyInfo.xcprivacy
- libssh2 crypto backend: OpenSSL; MD5, RIPEMD, RSA-SHA1, SHA-1 KEX/MACs,
  Blowfish, RC4, CAST, 3DES, and CBC are off (upstream defaults and
  LIBSSH2_NO_AES_CBC); ML-KEM hybrid key exchanges available
- Build command: make ssh-artifacts
EOF

(
    cd "${WORK_DIR}"
    find Artifacts -type f ! -name SHA256SUMS -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 > "${GENERATED_ARTIFACTS}/SHA256SUMS"
)

ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"
rm -rf "${ARTIFACT_DIR}"
mv "${GENERATED_ARTIFACTS}" "${ARTIFACT_DIR}"

"${SCRIPT_DIR}/verify-native.sh"
echo "Built and verified HeelerSSH native artifacts."
