# CLAUDE.md

Snag is Michael Henry's repo (`mghenry13/snag`). Ryan (`RyanCadby`) is a collaborator with push access. Treat `main` as Michael's and work only on Ryan's branch.

## Branch rules (read before any git write)

- **Ryan's production branch is `rc-main`.** Every edit, commit and push goes there, or to a short-lived feature branch cut from `rc-main` that merges back into `rc-main`.
- **Never push to, merge into, rebase onto, force-push or delete `main`** unless Michael has explicitly authorized that specific change. Ryan's own approval is not enough for `main`. Michael's sign-off must be stated in the conversation, for example "Michael approved merging X to main".
- **Pushing to `main` ships a release.** `.github/workflows/release.yml` runs on every push to `main` (except Markdown-only changes): it builds and signs the app, publishes the Sparkle appcast, and every installed copy of Snag auto-updates. A careless push to `main` reaches every user.
- To get work onto `main`, open a PR from `rc-main` (or a feature branch) to `main` and let Michael review and merge it. Do not merge it yourself.
- Before every push, run `git branch --show-current` and make sure the target is not `main`.
- Do not change repo settings, secrets (`gh secret set`), releases or tags without Michael's authorization. Releases are made from `main` only, by Michael.
- Ask before pushing, even to `rc-main`.

### Staying current with Michael's work

```bash
git fetch origin
git checkout rc-main
git merge origin/main      # pull Michael's changes into rc-main; never the other direction
git push origin rc-main
```

## Running it

Requires Xcode / the command line tools, macOS 14+.

```bash
./build.sh          # build build/Snag.app and build/snag-mcp
./build.sh run      # build, install to /Applications/Snag.app, launch
```

- Always run the app from `/Applications`, not from `build/`, so the Sparkle updater keeps working.
- **Sparkle caveat:** the installed app checks Michael's appcast and can update itself to his latest `main` release, which replaces a locally built `rc-main` build. Rebuild with `./build.sh run` after an update, or turn off automatic updates in the app.
- The local API is at `http://127.0.0.1:41777` and is only up while the app is running.
- Library data is in `~/Pictures/Snag/`. Do not delete anything there by hand while the app is running.

## Layout

| Path | What |
|---|---|
| `Sources/` | Swift package: the Snag app and `snag-mcp` |
| `extension/` | Chrome extension (load unpacked) |
| `tools/` | release, appcast, tests, `migrate-eagle.py` |
| `updates/` | Cloudflare Worker that serves the Sparkle appcast |
| `SPEC.md` | Original product and build spec |

## Eagle migration

Ryan's Eagle library is `~/Eagle/Haven.library`. With Snag running:

```bash
python3 tools/migrate-eagle.py ~/Eagle/Haven.library
```

Re-running is safe because Snag dedupes items by content hash. Eagle itself is left untouched.
