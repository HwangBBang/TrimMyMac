#!/usr/bin/env bash
# Cut a Sparkle release: build + sign the app, package it as an update zip, and
# (re)generate the EdDSA-signed appcast. generate_appcast reads the private signing
# key from the login keychain (the one created by Sparkle's generate_keys), so macOS
# may prompt for keychain access — click Allow.
#
# Usage: ./scripts/release.sh <short-version> [build-number]
#   e.g. ./scripts/release.sh 0.2.0
#
# Then create a GitHub release tagged v<version> and upload dist/TrimMyMac-<version>.zip
# and dist/appcast.xml. SUFeedURL points at releases/latest/download/appcast.xml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

VERSION="${1:?usage: release.sh <short-version> [build-number]}"
BUILD="${2:-$(date +%Y%m%d%H%M)}"
REPO_SLUG="HwangBBang/TrimMyMac"
DIST="${ROOT_DIR}/dist"
APP_BUNDLE="${ROOT_DIR}/.build/bundle/TrimMyMac.app"

# 1. Build + sign the app at this version.
SHORT_VERSION="${VERSION}" BUILD_VERSION="${BUILD}" "${SCRIPT_DIR}/build-app.sh"

# 2. Package as a Sparkle update archive (zip with the .app as the top entry).
mkdir -p "${DIST}"
ZIP="${DIST}/TrimMyMac-${VERSION}.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP}"
echo "==> packaged ${ZIP}"

# 3. (Re)generate the EdDSA-signed appcast over everything in dist/.
#    Locally the private key is read from the login keychain. In CI there is no
#    keychain, so set SPARKLE_ED_KEY_FILE to a file containing the exported key
#    (generate_keys -x) — passed through as --ed-key-file.
GEN="$(find "${ROOT_DIR}/.build/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)"
[[ -x "${GEN}" ]] || { echo "ERROR: generate_appcast not found — run 'swift build' first." >&2; exit 1; }
GEN_ARGS=( --download-url-prefix "https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/" )
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    GEN_ARGS+=( --ed-key-file "${SPARKLE_ED_KEY_FILE}" )
fi
"${GEN}" "${GEN_ARGS[@]}" "${DIST}"
echo "==> appcast: ${DIST}/appcast.xml"

cat <<EOF

Next steps:
  1. Create GitHub release 'v${VERSION}' on ${REPO_SLUG}
  2. Upload assets:  ${ZIP}
                     ${DIST}/appcast.xml
  Sparkle clients poll releases/latest/download/appcast.xml and update automatically.
EOF
