#!/usr/bin/env python3
"""Fake lidrop phone with today's `hello`, for the Windows receiver or `cargo run -p lidrop-core --example headless`.

Runs on the Windows PC too (any Python 3), so the real overlay and tray can be tried with no phone.

  fake_phone.py [host] [--port 7777] [--id ID] [--name NAME] [--edge left|right|top|bottom]
                [--files N] [--size BYTES] [--video] [--cancel] [--ceremony] [--receive] [--check-saved FOLDER]

--ceremony  plays the connect ceremony first      --receive     waits for a drag from the computer instead
--video     sends one file as type 3 blocks, last block first
--check-saved FOLDER  checks every saved file against what was sent, byte for byte

The token is kept in ~/.lidrop-fake-phone.json per id, as the phone keeps it. Exits non-zero on any failure.
"""
import argparse, hashlib, json, os, socket, struct, sys, time, uuid

BLOCK = 256 * 1024
THUMB = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/"
    "wAALCABAAEABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AKp//9k="
)

ap = argparse.ArgumentParser()
ap.add_argument("host", nargs="?", default="127.0.0.1")
ap.add_argument("--port", type=int, default=7777)
ap.add_argument("--id", default="fake-phone")
ap.add_argument("--name", default="Fake Phone")
ap.add_argument("--edge", default="left")
ap.add_argument("--files", type=int, default=1)
ap.add_argument("--size", type=int, default=700_000)
ap.add_argument("--video", action="store_true")
ap.add_argument("--cancel", action="store_true")
ap.add_argument("--ceremony", action="store_true")
ap.add_argument("--receive", action="store_true")
ap.add_argument("--check-saved")
a = ap.parse_args()

KEYS = os.path.expanduser("~/.lidrop-fake-phone.json")
s = socket.create_connection((a.host, a.port), timeout=10)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
s.settimeout(60)


def send(kind, payload):
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
    s.sendall(struct.pack(">IB", len(payload) + 1, kind) + payload)


def exact(n):
    b = bytearray()
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d:
            raise EOFError("connection closed")
        b.extend(d)
    return bytes(b)


def frame():
    n = struct.unpack(">I", exact(4))[0]
    return exact(1)[0], exact(n - 1)


def msg(want=None):
    while True:
        kind, body = frame()
        if kind == 1:
            m = json.loads(body)
            if want is None or m.get("t") == want or m.get("t") == "error":
                return m


def fail(text):
    print("FAIL:", text)
    sys.exit(1)


keys = json.load(open(KEYS)) if os.path.exists(KEYS) else {}
send(1, {"t": "hello", "name": a.name, "v": 0, "id": a.id, "role": "main", "token": keys.get(a.id, "")})
print("hello sent; if this is a new id, answer Allow on the computer")
w = msg()
if w["t"] != "welcome":
    fail(f"expected welcome, got {w}")
print("welcome:", {k: v for k, v in w.items() if k != "token"})
if "token" in w:
    keys[a.id] = w["token"]
    json.dump(keys, open(KEYS, "w"))

if a.ceremony:
    best = 1e9
    for i in range(30):
        send(1, {"t": "pair", "state": "hold", "p": i / 29})
        if i % 10 == 0:
            t = time.time()
            send(1, {"t": "pair", "state": "ping"})
            if msg("pair").get("state") != "pong":
                fail("no pong")
            best = min(best, time.time() - t)
        time.sleep(1 / 30)
    send(1, {"t": "pair", "state": "burst"})
    print(f"ceremony: fastest ping {best * 1000:.1f} ms")
    time.sleep(1.2)

if a.receive:
    print("waiting for a drag from the computer; drag a file to its", w.get("edge"), "edge")
    start = msg("mdrag_start")
    print("mdrag_start:", {k: v for k, v in start.items() if k != "thumb"}, "thumb bytes:", len(start.get("thumb", "")))
    moves = 0
    while True:
        m = msg()
        if m["t"] == "mdrag_move":
            moves += 1
        elif m["t"] == "mdrag_end":
            print("mdrag_end:", m, "after", moves, "moves")
            if not m["commit"]:
                sys.exit(0)
            break
    if msg("file_begin")["t"] != "file_begin":
        fail("no file_begin")
    h, got = hashlib.sha256(), 0
    while True:
        kind, body = frame()
        if kind == 2:
            h.update(body)
            got += len(body)
        elif json.loads(body)["t"] == "file_end":
            break
    size = start["files"][0]["size"]
    if size >= 0 and size != got:
        fail(f"size mismatch {got}/{size}")  # Receiver.kt refuses the file in this case
    send(1, {"t": "saved", "id": start["id"], "index": 0, "path": "/storage/emulated/0/Download/lidrop/" + start["name"]})
    print(f"received {got} bytes sha256={h.hexdigest()}")
    time.sleep(0.3)
    sys.exit(0)

did = str(uuid.uuid4())
body = [os.urandom(a.size + i) for i in range(a.files)]
names = [f"fake-{did[:8]}-{i}.{'mp4' if a.video else 'bin'}" for i in range(a.files)]
files = [{"name": n, "size": len(b), "mime": "video/mp4" if a.video else "application/octet-stream"} for n, b in zip(names, body)]
send(1, {"t": "drag_start", "id": did, "name": names[0], "mime": files[0]["mime"], "size": files[0]["size"], "thumb": THUMB,
         "tile_dp": 192, "count": a.files, "files": files, "tile_mm": 35.5, "screen_mm": [68.0, 148.0]})
for i in range(61):
    p = i / 60
    send(1, {"t": "drag_move", "id": did, "edge": a.edge, "along": round(0.3 + 0.2 * p, 4), "overhang": round(p * 0.8, 4)})
    time.sleep(1 / 60)
send(1, {"t": "drag_end", "id": did, "commit": not a.cancel})
if a.cancel:
    print("cancelled")
    time.sleep(0.5)
    sys.exit(0)

for i, b in enumerate(body):
    if a.video:
        send(1, {"t": "file_begin", "id": did, "index": i, "stream": True, "size": len(b), "mime": "video/mp4"})
        for n in reversed(range((len(b) + BLOCK - 1) // BLOCK)):
            send(3, struct.pack(">I", n) + b[n * BLOCK : (n + 1) * BLOCK])
    else:
        send(1, {"t": "file_begin", "id": did, "index": i})
        for off in range(0, len(b), BLOCK):
            send(2, b[off : off + BLOCK])
    send(1, {"t": "file_end", "id": did, "index": i})
    m = msg("saved")
    if m["t"] != "saved":
        fail(str(m))
    print("saved:", m)
    if a.check_saved:
        where = os.path.join(a.check_saved, os.path.basename(m["path"].replace("\\", "/")))
        if open(where, "rb").read() != b:
            fail(f"{where} differs from what was sent")
        print("  byte for byte identical")
print("ok")
