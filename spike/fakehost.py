"""A stand-in RustDesk host for developing the client without a real PC.

Speaks the real direct-IP handshake (Hash challenge, password check,
LoginResponse with PeerInfo), then replays the H.264 test frames (a keyframe
plus the frames after it) in a loop at ~30 fps, echoing nothing. Frames come
from Packages/OxideKit/Tests/OxideKitTests/Fixtures (tools/make_fixtures.py).

    uv run --with protobuf python fakehost.py --password secret [--port 21118]
"""

import argparse
import hashlib
import pathlib
import secrets
import socket
import string
import threading
import time

import message_pb2 as pb
from probe import Reader, send

# A Windows-like mode list; the display starts at 1920×1080.
MODES = [(5120, 1440), (3840, 2160), (2560, 1440), (1920, 1080), (1680, 1050), (1600, 900),
         (1440, 900), (1280, 1024), (1280, 800), (1024, 768)]
ORIGINAL = (1920, 1080)

FIXTURES = pathlib.Path(__file__).parent.parent / "Packages/OxideKit/Tests/OxideKitTests/Fixtures"


def token(n):
    return "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def serve(conn, addr, password, frames):
    print(f"{addr}: connected", flush=True)
    r = Reader(conn)
    salt, challenge = token(32), token(6)
    m = pb.Message()
    m.hash.salt, m.hash.challenge = salt, challenge
    send(conn, m)
    m, _ = r.next()
    lr = m.login_request
    h1 = hashlib.sha256(password.encode() + salt.encode()).digest()
    if lr.password != hashlib.sha256(h1 + challenge.encode()).digest():
        reply = pb.Message()
        reply.login_response.error = "Wrong Password"
        send(conn, reply)
        print(f"{addr}: wrong password")
        return
    print(f"{addr}: logged in as {lr.my_name!r} (h264={lr.option.supported_decoding.ability_h264})")
    reply = pb.Message()
    pi = reply.login_response.peer_info
    pi.hostname, pi.platform, pi.version = "fakehost", "Windows", "1.5.3"
    d = pi.displays.add()
    d.width, d.height, d.name = *ORIGINAL, "FAKE"
    d.original_resolution.width, d.original_resolution.height = ORIGINAL
    for w, h in MODES:
        res = pi.resolutions.resolutions.add()
        res.width, res.height = w, h
    lock = threading.Lock()
    with lock:
        send(conn, reply)
    threading.Thread(target=lambda: _safe(listen, conn, addr, r, lock), daemon=True).start()

    pts = 0
    while True:
        for data, key in frames:
            m = pb.Message()
            f = m.video_frame.h264s.frames.add()
            f.data, f.key, f.pts = data, key, pts
            with lock:
                send(conn, m)
            pts += 33
            time.sleep(1 / 30)


def listen(conn, addr, reader, lock):
    """Answers resolution changes like a real host: SwitchDisplay with the new
    size if the mode is listed, silence if not."""
    while True:
        m, _ = reader.next()
        if m.WhichOneof("union") != "misc" or m.misc.WhichOneof("union") != "change_display_resolution":
            continue
        req = m.misc.change_display_resolution
        mode = (req.resolution.width, req.resolution.height)
        print(f"{addr}: change resolution of display {req.display} to {mode[0]}x{mode[1]}", flush=True)
        if mode not in MODES:
            print(f"{addr}: not a listed mode, ignored", flush=True)
            continue
        reply = pb.Message()
        sd = reply.misc.switch_display
        sd.display, sd.width, sd.height = req.display, *mode
        sd.original_resolution.width, sd.original_resolution.height = ORIGINAL
        for w, h in MODES:
            r = sd.resolutions.resolutions.add()
            r.width, r.height = w, h
        with lock:
            send(conn, reply)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--password", required=True)
    p.add_argument("--port", type=int, default=21118)
    args = p.parse_args()
    frames = [(f.read_bytes(), "-key" in f.name) for f in sorted(FIXTURES.glob("h264-*.bin"))]
    srv = socket.create_server(("0.0.0.0", args.port), reuse_port=True)
    print(f"fake host on :{args.port}, {len(frames)} frames")
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=lambda: _safe(serve, conn, addr, args.password, frames), daemon=True).start()


def _safe(fn, conn, addr, *a):
    try:
        fn(conn, addr, *a)
    except (OSError, EOFError) as e:
        print(f"{addr}: closed ({e})")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
