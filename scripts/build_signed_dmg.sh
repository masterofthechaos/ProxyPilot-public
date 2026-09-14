#!/usr/bin/env bash
#
# build_signed_dmg.sh — Build, sign, notarize, and staple a ProxyPilot macOS DMG
#
# Usage:
#   ./scripts/build_signed_dmg.sh              # uses version from project.yml
#   ./scripts/build_signed_dmg.sh 0.3.0        # override version string
#
# Output:
#   DMGs/ProxyPilot-vX.Y.Z.dmg  (notarized + stapled)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${0}")/.." && pwd)"
source "${ROOT_DIR}/scripts/release_channel.sh"

CHANNEL="stable"
if [[ "${1:-}" == "stable" || "${1:-}" == "alpha" ]]; then
  CHANNEL="$(pp_require_release_channel "${1}")"
  shift
fi

PROJECT="${ROOT_DIR}/ProxyPilot.xcodeproj"
SCHEME="ProxyPilot-macOS"
SPEC="${ROOT_DIR}/project.yml"
DMG_DIR="${ROOT_DIR}/DMGs"
NOTARY_PROFILE="YOUR_NOTARY_PROFILE"
SIGNING_IDENTITY_LABEL="Developer ID Application: Your Name (YOUR_TEAM_ID)"
TEAM_ID="YOUR_TEAM_ID"
CONFIGURATION="$(pp_release_configuration "${CHANNEL}")"
APP_WRAPPER_NAME="$(pp_app_wrapper_name "${CHANNEL}")"
APP_DISPLAY_NAME="$(pp_app_display_name "${CHANNEL}")"
BUILD_NUMBER="$(sed -nE 's/.*CURRENT_PROJECT_VERSION: "(.+)"/\1/p' "${SPEC}" | head -n 1)"

if [[ -n "${1:-}" ]]; then
  VERSION="$1"
else
  VERSION="$(sed -nE 's/.*MARKETING_VERSION: "(.+)"/\1/p' "${SPEC}" | head -n 1)"
fi

if [[ -z "${VERSION}" || -z "${BUILD_NUMBER}" ]]; then
  echo "Error: Could not determine version from ${SPEC}" >&2
  exit 1
fi

for cmd in xcodebuild hdiutil codesign xcrun; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "Error: ${cmd} not found" >&2; exit 1; }
done

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNING_IDENTITY_HASH="$(
  echo "${IDENTITIES}" \
    | awk -v label="${SIGNING_IDENTITY_LABEL}" -F'"' '$2 == label { print $1 }' \
    | awk '{ print $2 }' \
    | head -n 1
)"

if [[ -z "${SIGNING_IDENTITY_HASH}" ]]; then
  echo "Error: Signing identity not found: ${SIGNING_IDENTITY_LABEL}" >&2
  exit 1
fi

DMG_NAME="$(pp_dmg_name "${CHANNEL}" "${VERSION}" "${BUILD_NUMBER}")"
ARCHIVE="/tmp/ProxyPilot-${CHANNEL}-release.xcarchive"
STAGING="/tmp/ProxyPilot-${CHANNEL}-dmg-staging"
DMG_PATH="/tmp/${DMG_NAME}"
NOTARY_LOG="/tmp/notarytool-proxypilot-output.txt"

rm -rf "${ARCHIVE}" "${STAGING}"
rm -f "${DMG_PATH}" "${NOTARY_LOG}"

echo "Regenerating Xcode project (ensure version numbers flow from project.yml)..."
zsh "${ROOT_DIR}/scripts/update_xcodeproj.sh"

echo "Building ${APP_DISPLAY_NAME} v${VERSION}..."

xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -archivePath "${ARCHIVE}" \
  -configuration "${CONFIGURATION}" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  ENABLE_HARDENED_RUNTIME=YES \
  -quiet

APP_PATH="${ARCHIVE}/Products/Applications/${APP_WRAPPER_NAME}"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Error: Archive succeeded but app not found at ${APP_PATH}" >&2
  exit 1
fi

# Sanity check: verify the built app reports the expected version
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
if [[ "${BUILT_VERSION}" != "${VERSION}" ]]; then
  echo "Error: Version mismatch — project.yml says ${VERSION} but built app reports ${BUILT_VERSION}" >&2
  echo "  This usually means XcodeGen failed to regenerate the project." >&2
  exit 1
fi

echo "Signing Sparkle framework binaries (inside-out)..."
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"

# Sign XPC services
for xpc in "${SPARKLE_FW}/XPCServices"/*.xpc; do
  [[ -d "${xpc}" ]] || continue
  codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${xpc}"
done

# Sign helper binaries and apps
for helper in "${SPARKLE_FW}/Autoupdate" "${SPARKLE_FW}/Updater.app"; do
  [[ -e "${helper}" ]] || continue
  codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${helper}"
done

# Sign the framework itself
codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework"

# Sign any loose dynamic libraries in Frameworks/ (e.g., libswiftCompatibilitySpan.dylib)
for dylib in "${APP_PATH}/Contents/Frameworks"/*.dylib; do
  [[ -f "${dylib}" ]] || continue
  echo "  Signing $(basename "${dylib}")..."
  codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${dylib}"
done

# Sign embedded ProxyPilot CLI/Agent helpers before signing the containing app.
for helper in "${APP_PATH}/Contents/Helpers/proxypilot" "${APP_PATH}/Contents/Helpers/proxypilot-agent"; do
  [[ -f "${helper}" ]] || { echo "Error: Missing embedded helper: ${helper}" >&2; exit 1; }
  echo "  Signing $(basename "${helper}")..."
  codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${helper}"
done

# Sign the independently updatable RepoGPS payload, then regenerate its
# checksum manifest without replacing the immutable RepoGPS source commit.
REPOGPS_PAYLOAD="${APP_PATH}/Contents/Resources/RepoGPSPayload"
REPOGPS_BINARY="${REPOGPS_PAYLOAD}/bin/rgps"
[[ -x "${REPOGPS_BINARY}" ]] || { echo "Error: Missing embedded RepoGPS binary: ${REPOGPS_BINARY}" >&2; exit 1; }
REPOGPS_SOURCE_RELEASE="$(/usr/bin/plutil -extract source_release raw -o - "${REPOGPS_PAYLOAD}/payload.json")"
if [[ ! "${REPOGPS_SOURCE_RELEASE}" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "Error: Embedded RepoGPS source_release is not an immutable Git SHA" >&2
  exit 1
fi
echo "  Signing RepoGPS ${REPOGPS_SOURCE_RELEASE}..."
codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${REPOGPS_BINARY}"
"${REPOGPS_BINARY}" distribution make-manifest \
  --payload "${REPOGPS_PAYLOAD}" \
  --source-release "${REPOGPS_SOURCE_RELEASE}"
REPOGPS_EXPECTED_HASH="$(/usr/bin/jq -er '.files[] | select(.path == "bin/rgps") | .sha256' "${REPOGPS_PAYLOAD}/payload.json")"
REPOGPS_ACTUAL_HASH="$(shasum -a 256 "${REPOGPS_BINARY}" | awk '{print $1}')"
if [[ "${REPOGPS_EXPECTED_HASH}" != "${REPOGPS_ACTUAL_HASH}" ]]; then
  echo "Error: Embedded RepoGPS manifest does not match the signed binary" >&2
  exit 1
fi

echo "Signing main app bundle..."
codesign --force --sign "${SIGNING_IDENTITY_HASH}" --options runtime --timestamp "${APP_PATH}"

echo "Verifying signatures..."
codesign --verify --strict --verbose=2 "${APP_PATH}/Contents/Helpers/proxypilot"
codesign --verify --strict --verbose=2 "${APP_PATH}/Contents/Helpers/proxypilot-agent"
codesign --verify --strict --verbose=2 "${REPOGPS_BINARY}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

SIGN_FLAGS="$(codesign -dvv "${APP_PATH}" 2>&1 | grep 'flags=' || true)"
if ! echo "${SIGN_FLAGS}" | grep -q "runtime"; then
  echo "Error: Hardened runtime not enabled in signed app" >&2
  exit 1
fi

echo "Creating DMG..."
mkdir -p "${STAGING}"
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

hdiutil create \
  -volname "${APP_DISPLAY_NAME}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}" \
  -quiet

echo "Signing DMG..."
codesign --force --sign "${SIGNING_IDENTITY_HASH}" --timestamp "${DMG_PATH}"

echo "Submitting for notarization..."
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait 2>&1 | tee "${NOTARY_LOG}"

if ! grep -q "status: Accepted" "${NOTARY_LOG}"; then
  echo "Error: Notarization failed." >&2
  SUBMISSION_ID="$(grep 'id:' "${NOTARY_LOG}" | head -n 1 | awk '{print $2}')"
  if [[ -n "${SUBMISSION_ID}" ]]; then
    echo "Fetching notarization log for ${SUBMISSION_ID}..." >&2
    xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "${NOTARY_PROFILE}" || true
  fi
  exit 1
fi

echo "Stapling..."
xcrun stapler staple "${DMG_PATH}"

echo "Gatekeeper verification..."
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}"

mkdir -p "${DMG_DIR}"
mv "${DMG_PATH}" "${DMG_DIR}/${DMG_NAME}"

echo ""
echo "Done. Notarized DMG:"
echo "  ${DMG_DIR}/${DMG_NAME}"
ls -lh "${DMG_DIR}/${DMG_NAME}"

# ── Sparkle EdDSA signature ──────────────────────────────────────────────
SPARKLE_SIGN=""
for candidate in \
  "${HOME}/Downloads/Sparkle-for-Swift-Package-Manager/bin/sign_update" \
  "${HOME}/Library/Developer/Xcode/DerivedData"/ProxyPilot-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  "/usr/local/bin/sign_update"; do
  if [[ -x "${candidate}" ]]; then
    SPARKLE_SIGN="${candidate}"
    break
  fi
done

if [[ -n "${SPARKLE_SIGN}" ]]; then
  echo ""
  echo "Sparkle EdDSA signature (paste into appcast.xml <enclosure>):"
  "${SPARKLE_SIGN}" "${DMG_DIR}/${DMG_NAME}"
  echo ""
  echo "Authenticated CLI metadata (paste into proxypilot-versions.json):"
  echo "  sha256_cli: $(shasum -a 256 "${APP_PATH}/Contents/Helpers/proxypilot" | awk '{print $1}')"
  echo -n "  ed_signature_cli: "
  "${SPARKLE_SIGN}" "${APP_PATH}/Contents/Helpers/proxypilot" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p'
  echo ""
else
  echo ""
  echo "WARNING: Sparkle sign_update tool not found."
  echo "  Resolve SPM packages in Xcode first, or download from:"
  echo "  https://github.com/sparkle-project/Sparkle/releases"
  echo ""
fi

rm -rf "${ARCHIVE}" "${STAGING}" "${NOTARY_LOG}"
