# Snag

A native macOS visual library — save images, videos, and links from anywhere,
organize them into folders, and find them fast. Built with Swift + SwiftUI.
Think Eagle, but ours.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Install (easiest)

1. Download `Snag-x.y.z.zip` from the latest [Release](../../releases).
2. Unzip, drop **Snag.app** into `/Applications`, open it.
3. The app auto-updates via Sparkle (`menu bar icon → Check for Updates…`).

## Build from source

```bash
git clone git@github.com:mghenry13/snag.git
cd snag
./build.sh run
```

Requires Xcode command line tools (`xcode-select --install`). The script signs
with your Developer ID when you have one, otherwise ad-hoc (fine for local use).

## The pieces

| Piece | What it does |
|---|---|
| **Snag.app** | Library window, macOS-wide drop panel (`⌃⌥⌘B`, drag to right screen edge, or shake mid-drag), spacebar preview, hover-scrub videos |
| **Chrome extension** | Right-click saves, Save URL, area/visible captures, Meta Ad Library video saving. Works in Chrome, Arc, any Chromium browser |
| **snag-mcp** | Local MCP server so Claude can search/organize your library |
| **Local API** | `127.0.0.1:41777` — everything talks through this |

## Chrome extension install

Settings (`⌘,`) → **Chrome Extension** → *Reveal Extension Folder*, then:

1. Open `chrome://extensions`, enable **Developer mode**
2. **Load unpacked** → pick the revealed folder
3. Pin Snag to the toolbar

## Claude MCP

Settings (`⌘,`) → **Claude MCP** → copy the one-line command.

## Cloud backup (optional)

Fully local by default. To back up to your own Cloudflare R2 bucket:
Settings (`⌘,`) → **Cloud Backup** → paste your Account ID, an R2 API token's
Access Key + Secret, and a bucket name → Save → Sync Now. After that it syncs
on every launch. Content files upload once; the index uploads every sync.

## Data

Everything lives in `~/Pictures/Snag/` — originals in `files/`, the SQLite
index at `library.sqlite`, daily index snapshots in `backups/` (14 days kept).
Delete nothing by hand while the app runs.

## Releasing (maintainers)

```bash
# bump CFBundleShortVersionString + CFBundleVersion in Info.plist, then:
./tools/release.sh
```

Builds signed, notarizes when the `snag-notary` keychain profile exists,
Sparkle-signs the zip, publishes the appcast to the updates Worker, and
attaches the zip to a GitHub release.

## Auto-release from GitHub (CI)

Every push to `main` triggers `.github/workflows/release.yml`: signed build,
optional notarization, Sparkle-signed zip, appcast publish, GitHub release —
every installed copy then self-updates. Required repo secrets:

| Secret | What / where |
|---|---|
| `SPARKLE_PRIVATE_KEY` | ✅ already set |
| `CLOUDFLARE_ACCOUNT_ID` | ✅ already set |
| `MAC_CERT_P12_BASE64` | Keychain Access → export "Developer ID Application" as .p12 → `base64 -i cert.p12 \| pbcopy` |
| `MAC_CERT_PASSWORD` | the password you set on that .p12 |
| `CLOUDFLARE_API_TOKEN` | dash.cloudflare.com → API Tokens → "Edit Cloudflare Workers" template |
| `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD` | optional, enables notarization (team: VKXK2JE3PE) |

Until the cert secrets exist, the workflow skips with a warning instead of failing.
Set a secret with: `gh secret set NAME`
