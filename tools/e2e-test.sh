#!/bin/bash
# Snag end-to-end test suite: API, imports, dedupe, MCP, integrity, perf.
# Run while Snag.app is running. Cleans up everything it creates.
API="http://127.0.0.1:41777"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
check() { # check <desc> <actual> <expected-substr>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — got: ${2:0:120}"; fi
}

echo "=== 1. API health ==="
H=$(curl -s -m 5 "$API/health")
check "health endpoint" "$H" '"ok":true'

echo "=== 2. Folder CRUD ==="
FID=$(curl -s -X POST "$API/folders" -H 'Content-Type: application/json' -d '{"name":"__test_folder"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[[ -n "$FID" ]] && ok "folder create" || bad "folder create"
FL=$(curl -s "$API/folders")
check "folder list contains new folder" "$FL" "__test_folder"

echo "=== 3. Remote image import (full pipeline) ==="
T0=$(python3 -c 'import time; print(time.time())')
# picsum has gone down mid-run before, failing 8 checks that have nothing to
# do with Snag. Try it, then fall back to a stable host before blaming the app.
IMG_URL="https://picsum.photos/seed/snagtest$RANDOM/800/600.jpg"
if ! curl -s -o /dev/null -m 12 -f "$IMG_URL"; then
  echo "      (picsum unreachable — falling back to a stable image host)"
  IMG_URL="https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png"
fi
R=$(curl -s -m 30 -X POST "$API/items" -H 'Content-Type: application/json' -d "{\"url\":\"$IMG_URL\",\"folderId\":\"$FID\"}")
T1=$(python3 -c 'import time; print(time.time())')
ID1=$(echo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
[[ -n "$ID1" ]] && ok "remote import returns id" || bad "remote import: $R"
echo "      (import incl. download took $(python3 -c "print(f'{$T1-$T0:.2f}s')"))"
META=$(curl -s "$API/items/$ID1")
if [[ "$IMG_URL" == *picsum* ]]; then
  check "dimensions extracted" "$META" '"width":800'
else
  check "dimensions extracted" "$META" '"width":288'
fi
check "palette computed" "$META" '#'
check "folder assignment" "$META" "$FID"
FP=$(echo "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["filePath"])')
[[ -f "$FP" ]] && ok "original on disk" || bad "original missing: $FP"
TH=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' "$API/items/$ID1/thumbnail")
check "thumbnail served" "$TH" "200"

echo "=== 4. Duplicate detection ==="
B64=$(base64 -i "$FP" | tr -d '\n')
D=$(curl -s -X POST "$API/items" -H 'Content-Type: application/json' -d "{\"dataBase64\":\"$B64\",\"ext\":\"jpg\",\"name\":\"dupe-test\"}")
check "same bytes -> duplicate:true" "$D" '"duplicate":true'

echo "=== 5. Base64 capture upload ==="
PNG64=$(python3 - <<'EOF'
import struct, zlib, base64, random
size=32; px=bytearray()
for y in range(size):
    px.append(0)
    for x in range(size): px += bytes([random.randrange(256),random.randrange(256),random.randrange(256),255])
def chunk(t,d):
    c=struct.pack(">I",len(d))+t+d; return c+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
ihdr=struct.pack(">IIBBBBB",size,size,8,6,0,0,0)
print(base64.b64encode(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",ihdr)+chunk(b"IDAT",zlib.compress(bytes(px)))+chunk(b"IEND",b"")).decode())
EOF
)
C=$(curl -s -X POST "$API/items" -H 'Content-Type: application/json' -d "{\"dataBase64\":\"$PNG64\",\"ext\":\"png\",\"name\":\"__capture_test\",\"folderId\":\"$FID\"}")
ID2=$(echo "$C" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
[[ -n "$ID2" ]] && ok "base64 capture import" || bad "capture import: $C"

echo "=== 6. Bookmark import (title + og:image) ==="
BM=$(curl -s -m 30 -X POST "$API/items" -H 'Content-Type: application/json' -d "{\"url\":\"https://eagle.cool/blog\",\"folderId\":\"$FID\"}")
ID3=$(echo "$BM" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
[[ -n "$ID3" ]] && ok "bookmark import" || bad "bookmark: $BM"

echo "=== 7. Search + PATCH ==="
P=$(curl -s -X PATCH "$API/items/$ID1" -H 'Content-Type: application/json' -d '{"name":"__renamed_zebra_item","note":"zebra note","rating":4,"tags":["__zebratag"]}')
check "patch name" "$P" "__renamed_zebra_item"
S=$(curl -s "$API/items?query=zebra")
check "search finds renamed item" "$S" "$ID1"

echo "=== 8. MCP tools ==="
MCPOUT=$(cd ~/Claude/snag && python3 - <<'EOF'
import subprocess, json
p = subprocess.Popen(["build/snag-mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
msgs = [
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}},
    {"jsonrpc":"2.0","method":"notifications/initialized"},
    {"jsonrpc":"2.0","id":2,"method":"tools/list"},
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_items","arguments":{"query":"zebra"}}},
    {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_folders","arguments":{}}},
]
for m in msgs: p.stdin.write(json.dumps(m)+"\n")
p.stdin.close()
tools=search=folders="?"
for line in p.stdout.read().strip().split("\n"):
    r=json.loads(line)
    if r.get("id")==2: tools=len(r["result"]["tools"])
    if r.get("id")==3: search="zebra" if "zebra" in r["result"]["content"][0]["text"] else "missing"
    if r.get("id")==4: folders="__test_folder" if "__test_folder" in r["result"]["content"][0]["text"] else "missing"
print(f"tools={tools} search={search} folders={folders}")
EOF
)
check "mcp 8 tools listed" "$MCPOUT" "tools=8"
check "mcp search works" "$MCPOUT" "search=zebra"
check "mcp folders works" "$MCPOUT" "folders=__test_folder"

echo "=== 9. Soft delete ==="
DEL=$(curl -s -X DELETE "$API/items/$ID2")
check "delete responds ok" "$DEL" '"ok":true'
G=$(curl -s "$API/items?query=__capture_test")
[[ "$G" == "[]" ]] && ok "deleted item gone from list" || bad "deleted item still listed"

echo "=== 10. Integrity ==="
DBQ() { sqlite3 ~/Pictures/Snag/library.sqlite "$1"; }
ORPHAN_ROWS=$(DBQ "SELECT COUNT(*) FROM item WHERE deletedAt IS NULL" )
FILES=$(ls ~/Pictures/Snag/files | wc -l | tr -d ' ')
echo "      items(live)=$ORPHAN_ROWS files-on-disk=$FILES (files >= live items expected: trash keeps files)"
MISSING=$(python3 - <<'EOF'
import sqlite3, os
db = sqlite3.connect(os.path.expanduser("~/Pictures/Snag/library.sqlite"))
missing = 0
for id_, ext in db.execute("SELECT id, ext FROM item WHERE deletedAt IS NULL"):
    if not os.path.exists(os.path.expanduser(f"~/Pictures/Snag/files/{id_}.{ext}")): missing += 1
print(missing)
EOF
)
[[ "$MISSING" == "0" ]] && ok "every live item has its file on disk" || bad "$MISSING live items missing files"
THUMBLESS=$(python3 - <<'EOF'
import sqlite3, os
db = sqlite3.connect(os.path.expanduser("~/Pictures/Snag/library.sqlite"))
n = 0
for (id_,) in db.execute("SELECT id FROM item WHERE deletedAt IS NULL AND type != 'url'"):
    if not os.path.exists(os.path.expanduser(f"~/Pictures/Snag/thumbnails/{id_}.png")): n += 1
print(n)
EOF
)
echo "      media items without thumbnails: $THUMBLESS (0 ideal; URL bookmarks excluded)"

echo "=== 11. Performance ==="
python3 - <<EOF
import time, urllib.request, json
def bench(url, n=20):
    ts = []
    for _ in range(n):
        t0 = time.time()
        urllib.request.urlopen(url, timeout=5).read()
        ts.append((time.time()-t0)*1000)
    ts.sort()
    return ts[len(ts)//2], ts[-1]
med, worst = bench("$API/items?limit=200")
print(f"      items list (full library): median {med:.1f}ms, worst {worst:.1f}ms " + ("PASSOK" if med < 50 else "SLOW"))
med2, worst2 = bench("$API/folders")
print(f"      folders: median {med2:.1f}ms, worst {worst2:.1f}ms")
EOF
PSOUT=$(ps -axo rss,pcpu,comm | grep "Snag.app" | grep -v grep | head -1)
RSS=$(echo "$PSOUT" | awk '{printf "%.0f", $1/1024}')
CPU=$(echo "$PSOUT" | awk '{print $2}')
echo "      app footprint: ${RSS}MB RSS, ${CPU}% CPU idle"
[[ "$RSS" -lt 800 ]] && ok "memory under 800MB (${RSS}MB)" || bad "memory high: ${RSS}MB"

echo "=== 12. Cleanup ==="
for ID in "$ID1" "$ID3"; do [[ -n "$ID" ]] && curl -s -X DELETE "$API/items/$ID" > /dev/null; done
python3 - "$FID" "$ID1" "$ID2" "$ID3" <<'EOF'
import sqlite3, os, sys
fid = sys.argv[1]
ids = [i for i in sys.argv[2:] if i]
db = sqlite3.connect(os.path.expanduser("~/Pictures/Snag/library.sqlite"))
# SAFETY: delete ONLY the exact ids this run created. Never name patterns --
# a LIKE with underscores once deleted the whole library (underscore = wildcard).
assert len(ids) <= 3, "unexpected id count"
removed = 0
for id_ in ids:
    row = db.execute("SELECT ext FROM item WHERE id = ?", (id_,)).fetchone()
    if not row: continue
    for path in (f"~/Pictures/Snag/files/{id_}.{row[0]}", f"~/Pictures/Snag/thumbnails/{id_}.png"):
        try: os.remove(os.path.expanduser(path))
        except FileNotFoundError: pass
    db.execute("DELETE FROM item_tag WHERE itemId = ?", (id_,))
    db.execute("DELETE FROM item WHERE id = ?", (id_,))
    removed += 1
db.execute("DELETE FROM tag WHERE name = '__zebratag'")
db.execute("DELETE FROM folder WHERE id = ?", (fid,))
db.commit()
print(f"      removed {removed} test items + test folder")
EOF
# poke the app so it reloads state after the direct DB cleanup
CLEAN=$(curl -s -X POST "$API/folders" -H 'Content-Type: application/json' -d '{"name":"__poke"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
sqlite3 ~/Pictures/Snag/library.sqlite "DELETE FROM folder WHERE id = '$CLEAN';"
curl -s "$API/health" > /dev/null

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
