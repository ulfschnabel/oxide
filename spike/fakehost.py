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


LOG_MOUSE = False
LOG_KEYS = False
RESIZE_DELAY = 0.0
IGNORE_RESIZE = False


def listen(conn, addr, reader, lock):
    """Answers resolution changes like a real host: SwitchDisplay with the new
    size if the mode is listed, silence if not."""
    while True:
        m, _ = reader.next()
        if LOG_MOUSE and m.WhichOneof("union") == "mouse_event":
            e = m.mouse_event
            kind = {0: "move", 1: "down", 2: "up", 3: "wheel", 4: "trackpad"}.get(e.mask & 7, e.mask & 7)
            button = {1: "left", 2: "right", 4: "middle"}.get(e.mask >> 3, "")
            print(f"{addr}: mouse {kind} {button} {e.x},{e.y}".replace("  ", " "), flush=True)
            continue
        if LOG_KEYS and m.WhichOneof("union") == "key_event":
            k = m.key_event
            mode = {0: "legacy", 1: "map", 2: "translate"}.get(k.mode, k.mode)
            what = k.WhichOneof("union")
            value = hex(k.chr) if what == "chr" else getattr(k, what) if what else ""
            mods = [pb.ControlKey.Name(x) for x in k.modifiers]
            print(f"{addr}: key {mode} {what}={value} down={k.down} press={k.press} mods={mods}", flush=True)
            continue
        if m.WhichOneof("union") == "misc" and m.misc.WhichOneof("union") == "refresh_video":
            print(f"{addr}: refresh video", flush=True)
            continue
        if m.WhichOneof("union") != "misc" or m.misc.WhichOneof("union") != "change_display_resolution":
            continue
        req = m.misc.change_display_resolution
        mode = (req.resolution.width, req.resolution.height)
        print(f"{addr}: change resolution of display {req.display} to {mode[0]}x{mode[1]}", flush=True)
        if mode not in MODES or IGNORE_RESIZE:
            print(f"{addr}: ignored", flush=True)
            continue
        time.sleep(RESIZE_DELAY)
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
    p.add_argument("--log-mouse", action="store_true", help="print the mouse events the client sends")
    p.add_argument("--log-keys", action="store_true", help="print the key events the client sends")
    p.add_argument("--resize-delay", type=float, default=0.0, help="seconds before answering a resolution change")
    p.add_argument("--ignore-resize", action="store_true", help="never answer resolution changes")
    args = p.parse_args()
    global LOG_MOUSE, LOG_KEYS, RESIZE_DELAY, IGNORE_RESIZE
    LOG_MOUSE = args.log_mouse
    LOG_KEYS = args.log_keys
    RESIZE_DELAY = args.resize_delay
    IGNORE_RESIZE = args.ignore_resize
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
