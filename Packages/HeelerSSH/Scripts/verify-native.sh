#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${PACKAGE_DIR}/../.." && pwd)"
ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"
EXPECTED_TARGET="$(awk -F'"' '/^[[:space:]]*iOS: / { print $2; exit }' "${PROJECT_DIR}/project.yml")"
EXPECTED_MAJOR="${EXPECTED_TARGET%%.*}"

[[ -n "${EXPECTED_TARGET}" ]] || {
    echo "error: could not read the iOS deployment target from project.yml" >&2
    exit 1
}

grep -Fq ".iOS(.v${EXPECTED_MAJOR})" "${PACKAGE_DIR}/Package.swift" || {
    echo "error: HeelerSSH Package.swift does not target iOS ${EXPECTED_MAJOR}" >&2
    exit 1
}

grep -Fq "DEPLOYMENT_TARGET=\"${EXPECTED_TARGET}\"" "${SCRIPT_DIR}/build-native.sh" || {
    echo "error: native build target does not match iOS ${EXPECTED_TARGET}" >&2
    exit 1
}

cd "${PACKAGE_DIR}"
checksum_output="$(shasum -a 256 -c Artifacts/SHA256SUMS 2>&1)" || {
    echo "${checksum_output}" >&2
    exit 1
}

for framework in COpenSSL CLibSSH2; do
    info="${ARTIFACT_DIR}/${framework}.xcframework/Info.plist"
    [[ -f "${info}" ]] || {
        echo "error: missing ${framework} Info.plist" >&2
        exit 1
    }

    plutil -convert json -o - "${info}" \
        | grep -q '"SupportedArchitectures".*"arm64"' || {
            echo "error: ${framework} has no arm64 slice" >&2
            exit 1
        }
    plutil -convert json -o - "${info}" \
        | grep -q '"SupportedPlatformVariant":"simulator"' || {
            echo "error: ${framework} has no Simulator slice" >&2
            exit 1
        }

    for platform_info in "${ARTIFACT_DIR}/${framework}.xcframework"/*/*.framework/Info.plist; do
        minimum_version="$(plutil -extract MinimumOSVersion raw -o - "${platform_info}")"
        [[ "${minimum_version}" == "${EXPECTED_TARGET}" ]] || {
            echo "error: ${platform_info} targets iOS ${minimum_version}, expected ${EXPECTED_TARGET}" >&2
            exit 1
        }
    done
done

for library in \
    "${ARTIFACT_DIR}/COpenSSL.xcframework"/*/COpenSSL.framework/COpenSSL \
    "${ARTIFACT_DIR}/CLibSSH2.xcframework"/*/CLibSSH2.framework/CLibSSH2; do
    binary_targets="$(
        xcrun otool -l "${library}" \
            | awk '$1 == "minos" { print $2 }' \
            | LC_ALL=C sort -u
    )"
    [[ "${binary_targets}" == "${EXPECTED_TARGET}" ]] || {
        echo "error: ${library} contains deployment targets '${binary_targets}', expected ${EXPECTED_TARGET}" >&2
        exit 1
    }
done

for framework in "${ARTIFACT_DIR}/COpenSSL.xcframework"/*/COpenSSL.framework; do
    configuration="${framework}/Headers/openssl/configuration.h"
    privacy_manifest="${framework}/PrivacyInfo.xcprivacy"
    [[ -f "${configuration}" ]] || {
        echo "error: missing OpenSSL configuration header in ${framework}" >&2
        exit 1
    }
    [[ -f "${privacy_manifest}" ]] || {
        echo "error: missing OpenSSL privacy manifest in ${framework}" >&2
        exit 1
    }
    plutil -lint "${privacy_manifest}" >/dev/null
    privacy_json="$(plutil -convert json -o - "${privacy_manifest}")"
    grep -q '"NSPrivacyTracking":false' <<<"${privacy_json}" || {
        echo "error: OpenSSL privacy manifest must disable tracking" >&2
        exit 1
    }
    grep -q '"NSPrivacyCollectedDataTypes":\[\]' <<<"${privacy_json}" || {
        echo "error: OpenSSL privacy manifest must not declare collected data" >&2
        exit 1
    }
    grep -q '"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp"' \
        <<<"${privacy_json}" || {
            echo "error: OpenSSL privacy manifest is missing the file timestamp category" >&2
            exit 1
        }
    grep -q '"NSPrivacyAccessedAPITypeReasons":\["C617.1"\]' <<<"${privacy_json}" || {
        echo "error: OpenSSL privacy manifest is missing reason C617.1" >&2
        exit 1
    }

    for feature in \
        ARIA BF CAMELLIA CAST DEPRECATED DES DSA IDEA RC2 RC4 RMD160 SEED \
        SM2 SM3 SM4 WHIRLPOOL; do
        grep -Eq "^[[:space:]]*#[[:space:]]*define OPENSSL_NO_${feature}([[:space:]]|$)" \
            "${configuration}" || {
                echo "error: OpenSSL ${feature} support is enabled in ${framework}" >&2
                exit 1
            }
    done

    if strings "${framework}/COpenSSL" \
        | grep -Eqi 'legacy provider|providers/legacy|legacy\.so|ossl_legacy_provider_init'; then
        echo "error: OpenSSL legacy provider found in ${framework}" >&2
        exit 1
    fi
done

codesign --verify --strict "${ARTIFACT_DIR}/COpenSSL.xcframework" || {
    echo "error: COpenSSL XCFramework signature is invalid" >&2
    exit 1
}
openssl_team="$({ codesign -dv --verbose=4 \
    "${ARTIFACT_DIR}/COpenSSL.xcframework" 2>&1 || true; } \
    | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
[[ "${openssl_team}" == "9VM4RM39R3" ]] || {
    echo "error: COpenSSL XCFramework is signed by unexpected team '${openssl_team}'" >&2
    exit 1
}

for library in "${ARTIFACT_DIR}/CLibSSH2.xcframework"/*/CLibSSH2.framework/CLibSSH2; do
    forbidden="$({ strings "${library}" || true; } | grep -E '^(ssh-dss|diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|diffie-hellman-group-exchange-sha1|hmac-sha1|hmac-sha1-96|hmac-sha1-etm@openssh\.com|hmac-sha1-96-etm@openssh\.com|hmac-md5|hmac-md5-96|hmac-md5-etm@openssh\.com|hmac-ripemd160|hmac-ripemd160-etm@openssh\.com|aes(128|192|256)-cbc|3des-cbc|blowfish-cbc|arcfour|cast128-cbc)$' || true)"
    if [[ -n "${forbidden}" ]]; then
        echo "error: legacy SSH methods found in ${library}:" >&2
        echo "${forbidden}" >&2
        exit 1
    fi
done

grep -q 'OpenSSL features:.*legacy provider' Artifacts/PROVENANCE.md
grep -q 'OpenSSL privacy manifest: upstream' Artifacts/PROVENANCE.md
grep -q 'libssh2 crypto backend: OpenSSL' Artifacts/PROVENANCE.md
grep -Fq "Deployment target: iOS ${EXPECTED_TARGET}" Artifacts/PROVENANCE.md

echo "HeelerSSH artifact checksums, slices, privacy manifest, signature, provenance, and algorithm policy are valid."
