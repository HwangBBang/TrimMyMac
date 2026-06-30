#!/usr/bin/env bash
# Build, bundle, sign (named self-signed identity), and install TrimMyMac.app.
set -euo pipefail

# --- Resolve repo root (script lives in <root>/scripts) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

# --- Config ---
APP_NAME="TrimMyMac"
EXE_NAME="TrimMyMacApp"
BUNDLE_ID="com.hbh0112.trimmymac"
SHORT_VERSION="${SHORT_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-TrimMyMac Self-Signed}"
INSTALL_DIR="/Applications"

BUILD_DIR="${ROOT_DIR}/.build/bundle"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

# --- 0. Check for the signing identity; fall back to ad-hoc for the spike ---
ADHOC_FALLBACK=false
if ! security find-identity -v -p codesigning | grep -qF "${CODESIGN_IDENTITY}"; then
    echo "WARNING: code-signing identity '${CODESIGN_IDENTITY}' not found." >&2
    echo "         For production use, create it once via Keychain Access:" >&2
    echo "           Keychain Access > Certificate Assistant > Create a Certificate" >&2
    echo "           Name: ${CODESIGN_IDENTITY}, Type: Code Signing, Root: Self Signed" >&2
    echo "         See docs/codesign-setup.md for full instructions." >&2
    echo "" >&2
    echo "  *** SPIKE-ONLY FALLBACK: signing ad-hoc (-s -) ***" >&2
    echo "  *** Ad-hoc signing loses TCC/FDA on every rebuild.***" >&2
    echo "  *** Create the named identity before granting Full Disk Access. ***" >&2
    ADHOC_FALLBACK=true
fi

# --- 1. Compile release ---
echo "==> swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/${EXE_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "ERROR: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

# --- 2. Assemble the .app bundle ---
echo "==> assembling ${APP_NAME}.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${EXE_NAME}"
chmod +x "${MACOS_DIR}/${EXE_NAME}"

# Info.plist from template with version substitution.
sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/g" \
    -e "s/__BUILD_VERSION__/${BUILD_VERSION}/g" \
    "${ROOT_DIR}/scripts/Info.plist.template" > "${CONTENTS}/Info.plist"

# PkgInfo (harmless but conventional).
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# --- 3. Sign ---
if [[ "${ADHOC_FALLBACK}" == "true" ]]; then
    echo "==> codesign ad-hoc (SPIKE FALLBACK — not stable for TCC/FDA)"
    codesign --force \
        --sign - \
        --identifier "${BUNDLE_ID}" \
        --timestamp=none \
        "${APP_BUNDLE}"
else
    echo "==> codesign with '${CODESIGN_IDENTITY}'"
    codesign --force \
        --sign "${CODESIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --timestamp=none \
        "${APP_BUNDLE}"
fi

# Confirm signature & print the Designated Requirement (stable across rebuilds).
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
echo "---- Designated Requirement (must stay constant across rebuilds) ----"
codesign -d --requirements - "${APP_BUNDLE}" 2>&1 || true
echo "--------------------------------------------------------------------"

# --- 4. Install to /Applications ---
echo "==> installing to ${INSTALL_DIR}/${APP_NAME}.app"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"

echo "==> done: ${INSTALL_DIR}/${APP_NAME}.app (v${SHORT_VERSION} build ${BUILD_VERSION})"
echo "    launch with: open '${INSTALL_DIR}/${APP_NAME}.app'"
