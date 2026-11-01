#!/usr/bin/env python3
"""Fake lidrop phone: python3 tools/fake_phone.py [host] [--name NAME] [--files N] [--cancel] [--hold] [--edge left|right|top|bottom]  (PHONE edge the tile leaves through)"""
import base64, json, socket, struct, sys, time, uuid

THUMB_B64 = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAYKADAAQAAAABAAAAYAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAYABgAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQABv/aAAwDAQACEQMRAD8A8Looor+5D/bwKKKKACiiigAooooAKKKKACiiigD/0PC6KKK/uQ/28CiiigAooooAKKKKACiiigAooooA/9Hwuiiiv7kP9vAooooAKKKKACiiigAooooAKKKKAP/S8Looor+5D/bwKKKKACiiigAooooAKKKKACiiigD/0/C6KKK/uQ/28CiiigAooooAKKKKACiiigAooooA/9Twuiiiv7kP9vAooooAKKKKACiiigAooooAKKKKAP/Z"  # 96x96 solid magenta JPEG

def send(s, typ, payload):
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
    s.sendall(struct.pack(">IB", len(payload) + 1, typ) + payload)

def recv_frames(s, out):
    s.settimeout(0.05)
    try:
        d = s.recv(65536)
    except (socket.timeout, BlockingIOError):
        return
    out.extend(d)
    while len(out) >= 4:
        n = struct.unpack(">I", out[:4])[0]
        if len(out) < 4 + n:
            return
        typ, body = out[4], bytes(out[5:4 + n])
        del out[:4 + n]
        print("<-", typ, body.decode(errors="replace"))

host = next((a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith("--") and sys.argv[i - 1] not in ("--edge", "--name", "--files", "--wait", "--holdat")), "127.0.0.1")
opt = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
phone_name = opt("--name", "Fake Phone")
nfiles = int(opt("--files", "1"))
cancel = "--cancel" in sys.argv
edge = sys.argv[sys.argv.index("--edge") + 1] if "--edge" in sys.argv else "left"
s = socket.create_connection((host, 7777))
buf = bytearray()
send(s, 1, {"t": "hello", "name": phone_name, "v": 0})
did = str(uuid.uuid4())
data = b"hello from fake_phone %d\n" % time.time() * 200
files = [{"name": "fake%s.txt" % (i if nfiles > 1 else ""), "size": len(data), "mime": "text/plain"} for i in range(nfiles)]
send(s, 1, {"t": "drag_start", "id": did, "name": files[0]["name"], "mime": "text/plain",
            "size": len(data), "thumb": THUMB_B64, "tile_dp": 96, "files": files, "count": nfiles})
steps = 120  # ~2s at 60Hz
for i in range(steps + 1):
    p = i / steps
    if "--hold" in sys.argv and p > float(opt("--holdat", "0.7")):
        p = float(opt("--holdat", "0.7"))
        time.sleep(0.5)
    send(s, 1, {"t": "drag_move", "edge": edge, "id": did, "along": 0.3 + 0.2 * p, "overhang": p})
    recv_frames(s, buf)
    time.sleep(1 / 60)
time.sleep(0.4)
open("/tmp/fake_commit", "w").write(str(time.time()))   # marker so a screenshot script can sync on the commit
send(s, 1, {"t": "drag_end", "id": did, "commit": not cancel})
if not cancel:
    for n in range(nfiles):
        send(s, 1, {"t": "file_begin", "id": did, "index": n})
        for i in range(0, len(data), 65535):
            send(s, 2, data[i:i + 65535])
        send(s, 1, {"t": "file_end", "id": did, "index": n})
end = time.time() + float(opt('--wait', '3'))
while time.time() < end:
    recv_frames(s, buf)
s.close()
