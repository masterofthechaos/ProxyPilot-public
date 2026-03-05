# Building ProxyPilot -- Read Before Running

Before you can build and run ProxyPilot from source, you need to replace several placeholder values with your own. This page lists every file and line that needs attention.

## Quick Start (just want to run it locally)

If you only want to build and run from Xcode (no signing, no distribution), you only need to change the **bundle identifiers**. Sparkle, PostHog, and signing config can be left as placeholders or removed.

---

## 1. Bundle Identifiers -- `project.yml`

**File:** `project.yml` (lines 5, 47, 60)

Replace `com.yourname` with your own reverse-domain identifier (e.g. `com.janedoe`).

| Line | Setting | Placeholder | Change to |
|------|---------|-------------|-----------|
| 5 | `bundleIdPrefix` | `com.yourname` | Your reverse-domain prefix |
| 47 | `PRODUCT_BUNDLE_IDENTIFIER` | `com.yourname.ProxyPilot` | `com.<you>.ProxyPilot` |
| 60 | `PRODUCT_BUNDLE_IDENTIFIER` | `com.yourname.ProxyPilotTests` | `com.<you>.ProxyPilotTests` |

After editing, regenerate the Xcode project:

```bash
zsh scripts/update_xcodeproj.sh
```

---

## 2. Sparkle Auto-Update Keys -- `project.yml` + `Info.plist`

If you want Sparkle auto-updates for your fork, generate your own EdDSA key pair and host an appcast XML.

**Files:**
- `project.yml` (lines 41-42)
- `ProxyPilot/Info.plist` (lines 32-36)

| Setting | Placeholder | What to put |
|---------|-------------|-------------|
| `SUFeedURL` | `https://yoursite.com/appcast.xml` | URL to your hosted appcast XML |
| `SUPublicEDKey` | `YOUR_SPARKLE_EDDSA_PUBLIC_KEY` | Output of Sparkle's `generate_keys` tool |

Generate keys with:

```bash
# From Sparkle's tools (bundled with the SPM package or downloadable)
./bin/generate_keys
```

If you **don't want Sparkle**, remove the `SUFeedURL`, `SUPublicEDKey` lines from both files and remove the `Sparkle` package dependency from `project.yml`.

---

## 3. PostHog Analytics -- `project.yml` + `Info.plist`

**Files:**
- `project.yml` (line 43)
- `ProxyPilot/Info.plist` (line 32)

| Setting | Placeholder | What to put |
|---------|-------------|-------------|
| `POSTHOG_API_KEY` | `YOUR_POSTHOG_API_KEY_OR_REMOVE` | Your PostHog project API key |

If you **don't want analytics**, remove the `POSTHOG_API_KEY` lines from both files. The app's telemetry service checks for this key at runtime and disables remote analytics when it's missing.

---

## 4. Code Signing + Notarization -- `scripts/build_signed_dmg.sh`

Only needed if you're distributing a signed DMG. See `scripts/SETUP-BEFORE-BUILDING.md` for full details.

---

## Let an Agent Help

Paste the following prompt to Claude Code, Cursor, Copilot, or any coding agent to have it configure the placeholders for you:

```
Read BUILDING.md in this repo, then update the placeholder values in these files:

1. project.yml -- lines 5, 47, 60: replace "com.yourname" with my bundle ID prefix
2. project.yml -- lines 41-43: replace Sparkle and PostHog placeholders (or remove if I don't use them)
3. ProxyPilot/Info.plist -- lines 32-36: match the same Sparkle/PostHog values from project.yml

My bundle ID prefix is: com.XXXXX
My Sparkle EdDSA public key is: XXXXX (or "remove Sparkle")
My PostHog API key is: XXXXX (or "remove PostHog")
My appcast URL is: XXXXX (or "remove Sparkle")

After editing, run: zsh scripts/update_xcodeproj.sh
```
