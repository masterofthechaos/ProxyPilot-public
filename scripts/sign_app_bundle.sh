#!/bin/bash
# Sign an already-built app consistently before installing it locally.
set -euo pipefail
APP_PATH="${1:?Usage: sign_app_bundle.sh /path/to/ProxyPilot.app}"
# Public checkouts may use a different developer certificate. Select the only
# Developer ID Application identity, or require an explicit label when ambiguous.
SIGNING_IDENTITY_LABEL="${PROXYPILOT_SIGNING_IDENTITY:-}"
IDENTITY_ROWS="$(security find-identity -v -p codesigning | awk -F'"' '$2 ~ /^Developer ID Application: / && !seen[$2]++ { split($1, parts, " "); print parts[2] "|" $2 }')"
if [[ -n "$SIGNING_IDENTITY_LABEL" ]]; then
  IDENTITY_ROWS="$(printf '%s\n' "$IDENTITY_ROWS" | awk -F'|' -v label="$SIGNING_IDENTITY_LABEL" '$2 == label')"
fi
IDENTITY_COUNT="$(printf '%s\n' "$IDENTITY_ROWS" | awk 'NF { n++ } END { print n+0 }')"
if [[ "$IDENTITY_COUNT" != 1 ]]; then
  echo "Error: Select one Developer ID Application certificate using PROXYPILOT_SIGNING_IDENTITY; refusing ambiguous or ad-hoc signing." >&2
  exit 1
fi
SIGNING_IDENTITY_HASH="${IDENTITY_ROWS%%|*}"
SIGNING_IDENTITY_LABEL="${IDENTITY_ROWS#*|}"
SIGNING_TEAM="$(printf '%s\n' "$SIGNING_IDENTITY_LABEL" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
if [[ -z "$SIGNING_TEAM" ]]; then
  echo "Error: Could not determine signing team from Developer ID identity." >&2
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

for target in "$APP_PATH" "$APP_PATH/Contents/Frameworks/Sparkle.framework" "$APP_PATH/Contents/Helpers/proxypilot" "$APP_PATH/Contents/Helpers/proxypilot-agent" "$REPOGPS_BINARY"; do
  codesign -dv "$target" 2>&1 | grep -Fx "TeamIdentifier=$SIGNING_TEAM" >/dev/null || { echo "Error: signing team mismatch: $target" >&2; exit 1; }
done
