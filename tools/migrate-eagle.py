#!/usr/bin/env python3
"""Migrate an Eagle library into Snag via the local API.

Recreates the folder tree (nested), then imports every non-deleted item with
its original bytes, name, source URL, note, tags, and rating.
Safe to re-run: Snag dedupes by content hash.
"""
import base64
import json
import os
import sys
import urllib.request

API = "http://127.0.0.1:41777"
LIB = os.path.expanduser("~/Pictures/mh.library")


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as res:
        return json.load(res)


def main():
    meta = json.load(open(os.path.join(LIB, "metadata.json")))

    # 1. Folder tree (skip folders Eagle marks as deleted)
    existing = {f["name"]: f["id"] for f in api("GET", "/folders")}
    folder_map = {}  # eagle id -> snag id

    def make_folders(nodes, parent_snag_id):
        for node in nodes:
            name = node.get("name", "Untitled")
            if name in existing:
                snag_id = existing[name]
            else:
                snag_id = api("POST", "/folders", {"name": name, "parentId": parent_snag_id})["id"]
                existing[name] = snag_id
            folder_map[node["id"]] = snag_id
            make_folders(node.get("children", []), snag_id)

    make_folders(meta.get("folders", []), None)
    print(f"folders mapped: {len(folder_map)}")

    # 2. Items
    images_dir = os.path.join(LIB, "images")
    infos = sorted(d for d in os.listdir(images_dir) if d.endswith(".info"))
    imported = dupes = skipped = failed = 0

    for d in infos:
        info_path = os.path.join(images_dir, d, "metadata.json")
        try:
            info = json.load(open(info_path))
        except Exception:
            skipped += 1
            continue
        if info.get("isDeleted"):
            skipped += 1
            continue

        name = info.get("name", "Untitled")
        ext = (info.get("ext") or "").lower()
        folder_id = None
        for fid in info.get("folders", []):
            if fid in folder_map:
                folder_id = folder_map[fid]
                break

        src_url = info.get("url") or None
        note = info.get("annotation") or ""
        tags = info.get("tags") or []
        star = info.get("star") or 0

        try:
            if ext == "url":
                if not src_url:
                    skipped += 1
                    continue
                res = api("POST", "/items", {"url": src_url, "folderId": folder_id})
            else:
                # find the original file inside the .info dir
                files = [f for f in os.listdir(os.path.join(images_dir, d))
                         if f != "metadata.json" and not f.endswith("_thumbnail.png")
                         and not f.startswith(".")]
                if not files:
                    skipped += 1
                    continue
                raw = open(os.path.join(images_dir, d, files[0]), "rb").read()
                res = api("POST", "/items", {
                    "dataBase64": base64.b64encode(raw).decode(),
                    "ext": ext or files[0].rsplit(".", 1)[-1].lower(),
                    "name": name,
                    "folderId": folder_id,
                    "sourceURL": src_url,
                    "pageURL": src_url,
                })

            if res.get("duplicate"):
                dupes += 1
            else:
                imported += 1

            item_id = res.get("id")
            patch = {}
            if note:
                patch["note"] = note
            if star:
                patch["rating"] = int(star)
            if tags:
                patch["tags"] = tags
            if item_id and patch:
                api("PATCH", f"/items/{item_id}", patch)
        except Exception as e:
            failed += 1
            print(f"  FAILED {name}: {e}", file=sys.stderr)

    print(f"imported={imported} duplicates={dupes} skipped={skipped} failed={failed}")


if __name__ == "__main__":
    main()
