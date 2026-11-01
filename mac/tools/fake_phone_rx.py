#!/usr/bin/env python3
"""Fake phone RECEIVER (Mac→phone drag): python3 tools/fake_phone_rx.py [host] [--out DIR]
Prints mdrag_* messages (moves summarised), saves the received file, replies `saved`."""
import json, os, socket, struct, sys, time

def send(s, o):
    p = json.dumps(o).encode()
    s.sendall(struct.pack(">IB", len(p) + 1, 1) + p)

args = sys.argv[1:]
out = args[args.index("--out") + 1] if "--out" in args else "/tmp/lidrop_rx"
host = next((a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] not in ("--out", "--name"))), "127.0.0.1")
rx_name = args[args.index("--name") + 1] if "--name" in args else "Fake RX"
os.makedirs(out, exist_ok=True)
s = socket.create_connection((host, 7777))
send(s, {"t": "hello", "name": rx_name, "v": 0})
buf, moves, cur, name, f, names = bytearray(), [], None, "file", None, ["file"]
if "--startdrag" in args:   # become the "most recent drag_start" phone
    send(s, {"t": "drag_start", "id": "rx-start", "name": "x", "mime": "text/plain", "size": 1, "thumb": "", "tile_dp": 96})
    send(s, {"t": "drag_end", "id": "rx-start", "commit": False})
print("connected; waiting for mdrag_* (Ctrl-C to quit)")
while True:
    d = s.recv(1 << 20)
    if not d:
        break
    buf.extend(d)
    while len(buf) >= 4:
        n = struct.unpack(">I", buf[:4])[0]
        if len(buf) < 4 + n:
            break
        typ, body = buf[4], bytes(buf[5:4 + n])
        del buf[:4 + n]
        if typ == 2:
            f.write(body); continue
        m = json.loads(body)
        t = m.get("t")
        if t == "mdrag_move":
            moves.append(m); continue
        if moves:
            print(f"  {len(moves)} mdrag_move, overhang {moves[0]['overhang']:.2f}→{moves[-1]['overhang']:.2f}, along {moves[-1]['along']:.2f}")
            moves = []
        show = dict(m)
        if "thumb" in show:
            show["thumb"] = f"<{len(m['thumb'])} b64 chars>"
        print("<-", show)
        if t == "mdrag_start":
            names = [x["name"] for x in m.get("files", [])] or [m["name"]]
        elif t == "file_begin":
            name = names[m.get("index", 0)]
            f = open(os.path.join(out, name), "wb")
        elif t == "file_end":
            f.close(); path = os.path.join(out, name)
            print("saved", path, os.path.getsize(path), "bytes")
            send(s, {"t": "saved", "id": m["id"], "index": m.get("index", 0), "path": path})
