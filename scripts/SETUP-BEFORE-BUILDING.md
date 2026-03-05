# Signing Scripts -- Read Before Running

The `build_signed_dmg.sh` script builds, signs, notarizes, and staples a ProxyPilot DMG for distribution. It requires an Apple Developer account with a **Developer ID Application** certificate.

You only need this script if you're distributing signed binaries. For local development builds, use `build_and_install.sh` or build directly in Xcode.

---

## Placeholders to Replace

**File:** `build_signed_dmg.sh` (lines 21-23)

| Line | Variable | Placeholder | What to put |
|------|----------|-------------|-------------|
| 21 | `NOTARY_PROFILE` | `YOUR_NOTARY_PROFILE` | Your `notarytool` keychain profile name |
| 22 | `SIGNING_IDENTITY_LABEL` | `Developer ID Application: Your Name (YOUR_TEAM_ID)` | Your full signing identity string |
| 23 | `TEAM_ID` | `YOUR_TEAM_ID` | Your 10-character Apple Team ID |

---

## How to Find Your Values

### Team ID

```bash
# List your signing identities
security find-identity -v -p codesigning
```

Look for `Developer ID Application: Your Name (XXXXXXXXXX)`. The 10-character code in parentheses is your Team ID.

### Notary Profile

If you haven't stored notarization credentials yet:

```bash
xcrun notarytool store-credentials "notarytool" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

The first argument (`"notarytool"`) is the profile name. Use whatever name you chose as `NOTARY_PROFILE`.

---

## Let an Agent Help

Paste the following prompt to Claude Code, Cursor, Copilot, or any coding agent:

```
Read scripts/SETUP-BEFORE-BUILDING.md, then update scripts/build_signed_dmg.sh:

- Line 21: set NOTARY_PROFILE to "XXXXX"
- Line 22: set SIGNING_IDENTITY_LABEL to "Developer ID Application: XXXXX (XXXXX)"
- Line 23: set TEAM_ID to "XXXXX"

My signing identity label is: XXXXX
My Team ID is: XXXXX
My notary profile name is: XXXXX
```
