"""Regenerates the H.264 test fixtures: ten 1920×1080 frames of ffmpeg's
test pattern, laid out like a RustDesk host sends them (Annex-B, keyframe
with SPS/PPS in-band, then P-frames, no B-frames). Needs ffmpeg with libx264.

    python3 tools/make_fixtures.py
"""
import pathlib, subprocess, tempfile

OUT = pathlib.Path(__file__).resolve().parent.parent / "Packages/OxideKit/Tests/OxideKitTests/Fixtures"

with tempfile.TemporaryDirectory() as tmp:
    raw = pathlib.Path(tmp) / "stream.h264"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30",
                    "-frames:v", "10", "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
                    "-bf", "0", "-g", "300", "-x264-params", "aud=1", "-f", "h264", str(raw)], check=True)
    data = raw.read_bytes()

# Split at access unit delimiters (NAL type 9), then drop them.
starts = [i for i in range(len(data) - 4)
          if data[i:i + 4] == b"\x00\x00\x00\x01" and data[i + 4] & 0x1F == 9]
units = [data[a:b] for a, b in zip(starts, starts[1:] + [len(data)])]
assert len(units) == 10, len(units)
for old in OUT.glob("h264-*.bin"):
    old.unlink()
for i, unit in enumerate(units):
    assert unit[4] & 0x1F == 9
    frame = unit[6:]  # the delimiter: 4-byte start code, NAL header, one payload byte
    (OUT / f"h264-{i:02d}{'-key' if i == 0 else ''}.bin").write_bytes(frame)
print(f"wrote {len(units)} frames to {OUT}")
