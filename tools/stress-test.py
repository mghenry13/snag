import json, os, random, sqlite3, struct, time, urllib.request, zlib, base64

API = "http://127.0.0.1:41777"

def api(method, path, body=None):
    req = urllib.request.Request(API + path,
                                 data=json.dumps(body).encode() if body else None,
                                 method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

def make_png(seed, size=256):
    random.seed(seed)
    px = bytearray()
    base = (random.randrange(256), random.randrange(256), random.randrange(256))
    for y in range(size):
        px.append(0)
        for x in range(size):
            px += bytes([(base[0] + x) % 256, (base[1] + y) % 256, base[2], 255])
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(px))) + chunk(b"IEND", b"")

N = 150
ids = []
t0 = time.time()
times = []
for i in range(N):
    png = make_png(f"stress-{time.time()}-{i}")
    ta = time.time()
    r = api("POST", "/items", {"dataBase64": base64.b64encode(png).decode(),
                               "ext": "png", "name": f"__stress_{i}"})
    times.append(time.time() - ta)
    ids.append(r["id"])
total = time.time() - t0
times.sort()
print(f"imported {N} items in {total:.1f}s "
      f"(median {times[len(times)//2]*1000:.0f}ms, p95 {times[int(len(times)*0.95)]*1000:.0f}ms per import)")

# list latency at scale
lat = []
for _ in range(15):
    ta = time.time()
    items = api("GET", "/items?limit=500")
    lat.append((time.time() - ta) * 1000)
lat.sort()
print(f"library now {len(items)} listed; list latency median {lat[len(lat)//2]:.1f}ms, worst {lat[-1]:.1f}ms")

rss = os.popen("ps -axo rss,comm | grep 'Snag.app' | grep -v grep | head -1").read().split()
print(f"app memory under load: {int(rss[0])//1024}MB")

# cleanup: EXACT ids only
db = sqlite3.connect(os.path.expanduser("~/Pictures/Snag/library.sqlite"))
removed = 0
for id_ in ids:
    row = db.execute("SELECT ext FROM item WHERE id = ?", (id_,)).fetchone()
    if not row:
        continue
    for p in (f"~/Pictures/Snag/files/{id_}.{row[0]}", f"~/Pictures/Snag/thumbnails/{id_}.png"):
        try: os.remove(os.path.expanduser(p))
        except FileNotFoundError: pass
    db.execute("DELETE FROM item WHERE id = ?", (id_,))
    removed += 1
db.commit()
print(f"cleaned up {removed}/{N} stress items")

# nudge the app to reload state after direct DB cleanup
first = api("GET", "/items?limit=1")[0]["id"]
api("PATCH", f"/items/{first}", {})
final = db.execute("SELECT COUNT(*) FROM item WHERE deletedAt IS NULL").fetchone()[0]
print(f"final live count: {final}")
