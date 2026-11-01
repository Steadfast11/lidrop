#!/usr/bin/env python3
"""Scripted fake phone for judging the light effects: slow approach, hold, retreat, approach again, commit.
python3 tools/fake_phone_demo.py [--edge left|right|top|bottom] [--cancel-end]   (writes /tmp/fake_commit at the end)"""
import json, socket, struct, sys, time, uuid
THUMB_B64 = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAYKADAAQAAAABAAAAYAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAYABgAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQABv/aAAwDAQACEQMRAD8A8Looor+5D/bwKKKKACiiigAooooAKKKKACiiigD/0PC6KKK/uQ/28CiiigAooooAKKKKACiiigAooooA/9Hwuiiiv7kP9vAooooAKKKKACiiigAooooAKKKKAP/S8Looor+5D/bwKKKKACiiigAooooAKKKKACiiigD/0/C6KKK/uQ/28CiiigAooooAKKKKACiiigAooooA/9Twuiiiv7kP9vAooooAKKKKACiiigAooooAKKKKAP/Z"
def send(s, typ, payload):
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
    s.sendall(struct.pack(">IB", len(payload) + 1, typ) + payload)
edge = sys.argv[sys.argv.index("--edge") + 1] if "--edge" in sys.argv else "left"
s = socket.create_connection(("127.0.0.1", 7777)); s.setblocking(False)
send(s, 1, {"t": "hello", "name": "Demo Phone", "v": 0})
did = str(uuid.uuid4()); data = b"demo file\n" * 50
send(s, 1, {"t": "drag_start", "id": did, "name": "demo.txt", "mime": "text/plain", "size": len(data), "thumb": THUMB_B64, "tile_dp": 96})
# (duration s, overhang from, overhang to)
phases = [(1.6, 0.0, 0.8), (1.0, 0.8, 0.8), (1.2, 0.8, 0.0), (0.6, 0.0, 0.0), (1.2, 0.0, 1.0), (0.3, 1.0, 1.0)]
t0 = time.time(); total = sum(p[0] for p in phases)
while True:
    t = time.time() - t0
    if t >= total: break
    acc = 0
    for d, a, b in phases:
        if t < acc + d:
            f = (t - acc) / d; o = a + (b - a) * f; break
        acc += d
    send(s, 1, {"t": "drag_move", "id": did, "edge": edge, "along": 0.45, "overhang": o})
    try: s.recv(65536)
    except BlockingIOError: pass
    time.sleep(1 / 60)
open("/tmp/fake_commit", "w").write(str(time.time()))
cancel = "--cancel-end" in sys.argv
send(s, 1, {"t": "drag_end", "id": did, "commit": not cancel})
if not cancel:
    send(s, 1, {"t": "file_begin", "id": did, "index": 0}); send(s, 2, data); send(s, 1, {"t": "file_end", "id": did, "index": 0})
time.sleep(2.5)
