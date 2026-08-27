# Snag — Full Build Plan

You are building **Snag**, a native macOS visual asset library inspired by Eagle (eagle.cool). This document is self-contained. Follow it exactly where it says "locked" and use your judgment elsewhere.

**Work in this folder:** `~/Claude/snag`
---

## 1. Product overview

Snag captures images, videos, and URL bookmarks into a local library, then lets the owner browse them in an Eagle-style window. Three capture paths:

1. **Drop panel (the killer feature):** when the user starts dragging a file or image ANYWHERE in macOS (Finder, Chrome, Figma, Photos), a floating panel slides in at the screen edge showing the folder list. Dropping on a folder saves the item into it. The panel must be non-activating (the app the user is dragging from keeps focus).
2. **Chrome extension:** right-click any image or video → "Save to Snag" with a folder submenu. Sends the URL to the local API, which downloads the full-resolution original.
3. **MCP server:** a local stdio MCP so Claude/agents can search, read, add, and organize items.

## 2. Locked decisions

- **Language/stack:** Swift + SwiftUI (AppKit where needed, e.g. NSPanel, NSEvent monitors). Native only. No Electron.
- **App presence:** dock icon AND menu bar icon. Launch at login (SMAppService).
- **Library location :** `~/Pictures/Snag/`
  - Originals in `files/<itemId>.<ext>`, thumbnails in `thumbnails/<itemId>.png`, SQLite DB at `library.sqlite`.
- **Local API port :** `41777`, bind 127.0.0.1 only.
- **Item types:** images (jpg/png/webp/gif/svg/heic), videos (mp4/mov/webm), URL bookmarks (a saved link with a title, domain, and a preview image when available).
- **Folders:** nested tree (folders can contain folders). Items live in at most one folder; "Uncategorized" is the null-folder state, not a real folder.
- **Tags:** free-form, many per item.
- **Metadata per item:** source URL, page URL, save date, modified date, dimensions, file size, dominant color palette (5–7 swatches), free-text note, star rating (0–5).
- **Duplicates:** SHA-256 of file contents. On duplicate import: do not save; surface "already saved" and reference the existing item.
- **Database:** SQLite via GRDB.swift.
- **Trash:** soft delete (deletedAt timestamp), a Trash view, empty-trash hard delete.

## 3. Main window UI (copy this layout closely)

Dark theme, SF Pro, SF Symbols. Three columns:

**Left sidebar (~230 pt):**
- Top: library name with a small colored icon and a switcher chevron.
- Smart items with counts, right-aligned numbers: All, Uncategorized, Untagged, Recently Used, Random, All Tags, Trash.
- Section label "Folders (n)".
- Nested folder tree: disclosure triangles, folder icons, item counts right-aligned. Drag-and-drop of items onto folder rows moves them.
- Bottom: a small "Filter" text field that filters the folder tree.

**Center — toolbar + grid:**
- Toolbar: back/forward chevrons, current-location breadcrumb ("All" or folder name), a zoom slider with − / + that controls thumbnail size, a search field (name, note, tag, domain), and a filter icon.
- Grid: adaptive columns of rounded-corner thumbnail cards. Aspect-fit thumbnails. Type badge overlay in the top-left of the card where relevant: "URL" for bookmarks, "SVG", "Youtube". Below each card: item name (one or two lines), then a gray caption — dimensions for files ("2880 × 2160"), domain for bookmarks ("get.arcads.ai").
- Selection: click selects (blue border), arrow keys navigate, space could Quick Look later (optional).

**Right inspector (~250 pt), for the selected item:**
- Large preview thumbnail.
- Row of circular palette swatches (the item's dominant colors).
- Editable title.
- "Notes..." multiline field.
- Source URL field with an open-link button.
- Tags section: chips + "＋ New tag".
- Folders section: current folder + "＋ Add Category" (folder picker).
- Properties list: Rating (5 stars, clickable), Dimensions, Size, Type, Date Imported, Date Created, Date Modified.
- "Export" button: saves a copy of the original via NSSavePanel.

## 4. Drop panel behavior (be precise here)

- Global monitors: `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged)` plus a local monitor for in-app drags. Mouse monitors need no accessibility permission.
- On drag events, read `NSPasteboard(name: .drag)`. Track `changeCount` so each drag is evaluated once. If the drag pasteboard contains file URLs, images, or web URLs → slide the panel in at the right screen edge. Text-only drags: stay hidden.
- Panel: `NSPanel` with `.nonactivatingPanel`, level `.floating`, `collectionBehavior` includes `.canJoinAllSpaces` and `.fullScreenAuxiliary`.
- Panel content: a drop target list of folders (the tree, flattened with indentation) + an "Inbox / Uncategorized" target at top. Highlight rows on drag-over. Accept `.fileURL`, `.image`, `.url` via NSItemProvider.
- On `leftMouseUp` (global monitor): hide the panel after a short delay if nothing was dropped.
- After a successful drop: brief confirmation state ("Saved to <folder>"), then slide out. On duplicate: show "Already saved".

## 5. Import pipeline

1. Receive file URL / image data / web URL.
2. Web image URLs: download with URLSession (follow redirects, keep original bytes and extension from Content-Type). Plain web page URLs become URL-bookmark items (fetch `<title>` and og:image for the preview when possible).
3. SHA-256 hash → duplicate check against DB.
4. Copy original into `files/`. Never re-encode originals.
5. Extract dimensions (CGImageSource for images, AVAsset for videos).
6. Generate a 512 px thumbnail (QuickLookThumbnailing handles both images and videos).
7. Compute a 5–7 color palette from a downsampled bitmap (simple quantization is fine).
8. Insert DB row, notify UI.

## 6. Data model (SQLite)

- `folder(id TEXT PK, name TEXT, parentId TEXT NULL, position INT, createdAt)`
- `item(id TEXT PK, name, type TEXT CHECK(image|video|url), ext, folderId TEXT NULL, sizeBytes INT, width INT, height INT, sourceURL TEXT, pageURL TEXT, note TEXT, colors TEXT /*JSON array of hex*/, hash TEXT UNIQUE, rating INT DEFAULT 0, createdAt, modifiedAt, deletedAt NULL)`
- `tag(id TEXT PK, name TEXT UNIQUE)`
- `item_tag(itemId, tagId, PK(itemId, tagId))`

## 7. Local HTTP API (127.0.0.1:41777)

JSON. Endpoints:
- `GET /health` → `{ok: true, version}`
- `GET /folders` → tree
- `POST /folders` `{name, parentId?}`
- `GET /items?query=&folderId=&tag=&limit=&offset=`
- `GET /items/:id` (metadata) and `GET /items/:id/file` (original bytes), `GET /items/:id/thumbnail`
- `POST /items` `{url, pageURL?, folderId?}` → download and import (used by the Chrome extension)
- `PATCH /items/:id` (name, note, folderId, rating, tags)
- `DELETE /items/:id` (soft delete)

## 8. Chrome extension (Manifest V3)

- Context menu on images: "Save to Snag" → submenu of folders (fetched from `GET /folders`, cached, refreshed on menu open).
- Context menu on video elements where a `src` is exposed.
- On click: `POST http://127.0.0.1:41777/items` with `{url: srcUrl, pageURL: tab.url, folderId}`.
- Badge/notification on success, distinct state for "already saved" and for "Snag app not running".
- `host_permissions`: `http://127.0.0.1:41777/*`.

## 9. MCP server

- Swift, official `modelcontextprotocol/swift-sdk`, stdio transport. Separate executable target `snag-mcp` that calls the HTTP API.
- Tools: `search_items(query, folder?, tag?, limit)`, `get_item(id)` (metadata + local file path), `list_folders()`, `create_folder(name, parentId?)`, `add_item(url|filePath, folderId?)`, `move_item(id, folderId)`, `set_note(id, note)`, `add_tags(id, tags[])`.
- Register with: `claude mcp add --scope user snag -- <path-to-binary>`.

## 10. Packaging

- Swift Package (executable target) is fine; assemble a proper `Snag.app` bundle with a build script: Info.plist (bundle id `com.mh.snag`, display name "Snag"), copy binary, ad-hoc codesign. Dock icon visible (LSUIElement = false).
- App must survive relaunch: DB migrations idempotent, library folder created on first run.

## 11. Build order + acceptance

1. **Core:** library folder + DB + import pipeline + main window (sidebar, grid, inspector). Accept: drop a file onto the window, see it in the grid with thumbnail, palette, dimensions; move it between folders; search finds it.
2. **Drop panel:** global drag detection + panel drop targets. Accept: drag an image out of a browser with Snag in the background; panel appears; drop on a folder; item saved; duplicate re-drop shows "already saved".
3. **HTTP API + Chrome extension.** Accept: right-click-save a full-res image from a real site into a chosen folder.
4. **MCP.** Accept: from Claude Code, search returns items and `add_item` with a URL imports it.
5. **Polish:** launch at login, zoom slider persistence, empty states, Trash view, export.

Non-goals for now: R2/cloud sync, sharing, multi-library switching (show the switcher UI, single library behind it), AI descriptions.

## 12. Additions (from Eagle feature screenshots)

- **Ratings:** 0-5 stars, orange/yellow fill, clickable in inspector Properties. Filterable later.
- **Tags:** colored dot per tag (stable hash color). "All Tags" sidebar view shows a browsable tag cloud grouped list with counts; clicking a tag filters the grid. Tag groups come later.
- **Extension toolbar popup (Eagle-style):** Save URL, Batch Save (all page images over a min size), Capture Area (drag-select overlay, crop), Capture Visible (captureVisibleTab), Capture Page (later), Drag Feature toggle. Right-click context menus stay.
- **Find Similar (Pinterest plugin equivalent):** context menu on an item: Pinterest search (by item name) + Google Lens reverse search (by source URL when present).
- **Spacebar Preview:** space opens a large in-app preview of the selected item; left/right arrows move through the current grid; scroll or slider zooms (to ~300%+, "focus zooming"); esc or space closes. Videos play (AVKit).
- **Layouts:** toolbar Layout menu: Waterfall (masonry, default), Grid (uniform), List. Sort by: Date Added, Name, Size, Rating. "Show Name" toggle. Justified layout later.
- **Later:** right-click mouse gestures (hold right button + move to zoom/switch), tag groups, Capture Page stitch.
