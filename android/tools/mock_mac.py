#!/usr/bin/env python3
"""Mock lidrop Mac (stdlib only). Speaks docs/PROTOCOL.md on :7777 (--port to change).
Phone→Mac: prints messages, saves files. Mac→phone: `--mdrag FILE... [--medge right] [--mthumb x.jpg] [--nocommit]`
plays mdrag_start / mdrag_move / mdrag_end (+ the file) as soon as the phone says hello.
Prints incoming control messages (drag_move summarised), validates `edge`, saves files to ./mock_out/."""
import argparse, json, os, socket, struct, sys, threading, time, base64

PORT = 7777
ARGS = None
MTYPE = {"png": "image/png", "jpg": "image/jpeg", "mp4": "video/mp4", "txt": "text/plain", "pdf": "application/pdf"}
EDGES = {"left", "right", "top", "bottom"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_out")


def recvn(c, n):
    b = bytearray()
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise ConnectionError("closed")
        b += d
    return bytes(b)


def send(c, obj):
    p = json.dumps(obj).encode()
    c.sendall(struct.pack(">IB", len(p) + 1, 1) + p)


def mdrag(c):
    """Play the Mac side of a Mac→phone drag (PROTOCOL v0.4/v0.5); --mdrag takes one or more files."""
    time.sleep(ARGS.delay)
    paths = ARGS.mdrag
    metas = [{"name": os.path.basename(p), "size": os.path.getsize(p),
              "mime": MTYPE.get(os.path.basename(p).rsplit(".", 1)[-1].lower(), "application/octet-stream")} for p in paths]
    thumb = base64.b64encode(open(ARGS.mthumb, "rb").read()).decode() if ARGS.mthumb else ""
    mid = "mock-mdrag-1"
    send(c, {"t": "mdrag_start", "id": mid, "name": metas[0]["name"], "mime": metas[0]["mime"], "size": metas[0]["size"],
             "files": metas, "count": len(metas), "thumb": thumb, "tile_mm": 35.5, "edge": ARGS.medge})
    n = int(ARGS.approach * 60)
    for i in range(n + 1):  # cursor walks into the 24pt edge zone
        send(c, {"t": "mdrag_move", "id": mid, "along": 0.5 - 0.2 * i / n, "overhang": i / n}); time.sleep(1 / 60)
    for _ in range(int(ARGS.hold * 60)):  # hold on the edge so a screenshot can be taken
        send(c, {"t": "mdrag_move", "id": mid, "along": 0.3, "overhang": 1.0}); time.sleep(1 / 60)
    send(c, {"t": "mdrag_end", "id": mid, "commit": not ARGS.nocommit})
    print("MDRAG sent start/move/end files=%d commit=%s edge=%s" % (len(metas), not ARGS.nocommit, ARGS.medge), flush=True)
    if ARGS.nocommit:
        return
    for i, path in enumerate(paths):
        send(c, {"t": "file_begin", "id": mid, "index": i})
        t0 = time.time()
        with open(path, "rb") as f:
            while True:
                b = f.read(256 * 1024)
                if not b: break
                c.sendall(struct.pack(">IB", len(b) + 1, 2) + b)
        send(c, {"t": "file_end", "id": mid, "index": i})
        print(f"MDRAG file[{i}] {metas[i]['name']} sent {metas[i]['size']} bytes in {time.time()-t0:.2f}s", flush=True)


def serve(c):
    os.makedirs(OUT, exist_ok=True)
    moves, t0, bad = 0, None, 0
    edges_seen, cur, fh, total = {}, None, None, 0
    maxov = 0.0
    while True:
        n, = struct.unpack(">I", recvn(c, 4))
        typ = recvn(c, 1)[0]
        body = recvn(c, n - 1)
        if typ == 2:
            fh.write(body); total += len(body)
            assert len(body) <= 262144, "chunk > 256KiB"
            continue
        m = json.loads(body)
        t = m["t"]
        if t == "hello":
            print("HELLO", m)
            send(c, {"t": "welcome", "name": "MockMac"})
            if ARGS.mdrag:
                threading.Thread(target=mdrag, args=(c,), daemon=True).start()
        elif t == "drag_start":
            cur = m; moves = 0; t0 = None; edges_seen = {}; maxov = 0.0; bad = 0
            print("DRAG_START", {k: (v if k != "thumb" else f"<{len(v)} b64 chars>") for k, v in m.items()})
            print("  count=%s files=%s" % (m.get("count"), [f["name"] for f in m.get("files", [])]))
        elif t == "drag_move":
            t0 = t0 or time.time(); moves += 1
            e, a, o = m.get("edge"), m["along"], m["overhang"]
            if e not in EDGES or not (0 <= a <= 1) or not (0 <= o <= 1):
                bad += 1; print("BAD drag_move", m)
            edges_seen[e] = edges_seen.get(e, 0) + 1
            maxov = max(maxov, o)
            if moves % 30 == 1:
                print(f"DRAG_MOVE edge={e} along={a:.3f} overhang={o:.3f}")
        elif t == "drag_end":
            dt = (time.time() - t0) if t0 else 0
            print(f"DRAG_END commit={m['commit']} moves={moves} rate={moves/dt if dt else 0:.0f}Hz "
                  f"edges={edges_seen} maxOverhang={maxov:.2f} bad={bad}")
        elif t in ("saved", "error"):
            print("PHONE REPLY", m)
        elif t == "file_begin":
            idx = m.get("index", 0)
            fl = cur.get("files") or [cur]
            name = os.path.basename(fl[idx]["name"]); path = os.path.join(OUT, name)
            fh = open(path, "wb"); total = 0; print(f"FILE_BEGIN index={idx} count={cur.get('count', 1)}", path)
        elif t == "file_end":
            idx = m.get("index", 0); fl = cur.get("files") or [cur]
            fh.close(); print(f"FILE_END index={idx} {total} bytes (announced {fl[idx]['size']})", "OK" if total == fl[idx]["size"] else "SIZE MISMATCH")
            send(c, {"t": "saved", "id": m["id"], "index": idx, "path": fh.name})
        else:
            print("??", m)


def main():
    global ARGS, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--mdrag", nargs="+", help="file(s) to send Mac→phone after hello")
    ap.add_argument("--medge", default="right", choices=sorted(EDGES), help="MAC edge being crossed")
    ap.add_argument("--mthumb", help="JPEG for the tile")
    ap.add_argument("--nocommit", action="store_true")
    ap.add_argument("--delay", type=float, default=1.0)
    ap.add_argument("--approach", type=float, default=1.0, help="seconds to walk overhang 0→1")
    ap.add_argument("--hold", type=float, default=3.0, help="seconds to hold overhang=1 before release")
    ARGS = ap.parse_args(); PORT = ARGS.port
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", PORT)); s.listen(1)
    print(f"mock_mac listening on :{PORT}")
    while True:
        c, addr = s.accept(); c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("CONNECT", addr)
        try:
            serve(c)
        except Exception as e:
            print("DISCONNECT", e)


if __name__ == "__main__":
    main()
