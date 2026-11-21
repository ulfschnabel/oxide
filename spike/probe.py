"""Feasibility spike: direct-IP login to a stock RustDesk 1.5.3 host, then
watch what arrives for a few seconds (PeerInfo, codec, frames, keyframes)."""

import hashlib
import random
import socket
import sys
import time
from collections import Counter

import message_pb2 as pb

PORT = 21118
if __name__ == "__main__":
    HOST, PASSWORD = sys.argv[1], open(sys.argv[2]).read().strip()
    SECONDS = float(sys.argv[3]) if len(sys.argv) > 3 else 6


def send(sock, msg):
    body = msg.SerializeToString()
    n = len(body)
    for size in (1, 2, 3, 4):
        if n < 1 << (8 * size - 2):
            break
    header = ((n << 2) | (size - 1)).to_bytes(size, "little")
    sock.sendall(header + body)


class Reader:
    def __init__(self, sock):
        self.sock, self.buf = sock, b""

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise EOFError
            self.buf += chunk

    def next(self):
        self._need(1)
        size = (self.buf[0] & 3) + 1
        self._need(size)
        n = int.from_bytes(self.buf[:size], "little") >> 2
        self._need(size + n)
        body, self.buf = self.buf[size : size + n], self.buf[size + n :]
        m = pb.Message()
        m.ParseFromString(body)
        return m, n


def main():
    sock = socket.create_connection((HOST, PORT), timeout=10)
    r = Reader(sock)
    m, _ = r.next()
    assert m.WhichOneof("union") == "hash", m
    h1 = hashlib.sha256(PASSWORD.encode() + m.hash.salt.encode()).digest()
    h2 = hashlib.sha256(h1 + m.hash.challenge.encode()).digest()

    login = pb.Message()
    lr = login.login_request
    lr.username = HOST
    lr.password = h2
    lr.my_id = "oxide-spike"
    lr.my_name = "Oxide spike"
    lr.session_id = random.getrandbits(63)
    lr.version = "1.5.3"
    lr.my_platform = "iOS"
    dec = lr.option.supported_decoding
    dec.ability_h264 = 1
    dec.ability_h265 = 1
    dec.prefer = pb.SupportedDecoding.H264
    send(sock, login)

    start = time.time()
    kinds, frames, keys, sizes = Counter(), Counter(), 0, []
    first_frame_at = None
    while time.time() - start < SECONDS:
        try:
            m, n = r.next()
        except socket.timeout:
            break
        kind = m.WhichOneof("union")
        kinds[kind] += 1
        if kind == "login_response":
            which = m.login_response.WhichOneof("union")
            if which == "error":
                sys.exit(f"login error: {m.login_response.error}")
            pi = m.login_response.peer_info
            print(f"LOGIN OK  host={pi.hostname} platform={pi.platform} version={pi.version} current_display={pi.current_display}")
            for i, d in enumerate(pi.displays):
                print(f"  display {i}: {d.width}x{d.height} at ({d.x},{d.y}) name={d.name!r} original={d.original_resolution.width}x{d.original_resolution.height}")
            res = sorted({(x.width, x.height) for x in pi.resolutions.resolutions}, reverse=True)
            print(f"  {len(res)} modes, e.g. {res[:12]}")
            print(f"  encoding: {pi.encoding}")
        elif kind == "test_delay":
            send(sock, m)  # echo unchanged
        elif kind == "video_frame":
            codec = m.video_frame.WhichOneof("union")
            frames[codec] += 1
            first_frame_at = first_frame_at or time.time() - start
            for f in getattr(m.video_frame, codec).frames:
                sizes.append(len(f.data))
                if f.key:
                    keys += 1
                    if keys == 1:
                        nal = f.data[:64].hex()
                        print(f"  first keyframe ({codec}) {len(f.data)} bytes, starts {nal[:40]}...")
        elif kind == "misc":
            print("  misc:", m.misc.WhichOneof("union"))

    elapsed = time.time() - start
    total = sum(frames.values())
    print(f"messages: {dict(kinds)}")
    print(f"video: {dict(frames)} keyframes={keys} first frame after {first_frame_at and round(first_frame_at, 2)}s")
    if sizes:
        fps = total / max(elapsed - (first_frame_at or 0), 0.001)
        print(f"~{fps:.0f} fps, avg frame {sum(sizes) / len(sizes) / 1024:.1f} KiB, {sum(sizes) * 8 / elapsed / 1e6:.1f} Mbit/s")
    sock.close()


if __name__ == "__main__":
    main()
