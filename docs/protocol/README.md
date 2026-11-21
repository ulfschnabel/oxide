# RustDesk protocol, as Oxide speaks it

Pinned host: **RustDesk 1.5.3** (tag `1.5.3`, hbb_common `fae47e0`), Windows,
direct IP access over the LAN/VPN. No ID server, no relay. Written from the
source; each file cites `file:line` and marks what was not confirmed as
UNVERIFIED.

| Spec | Covers |
|---|---|
| [transport-auth.md](transport-auth.md) | TCP 21118, framing, (no) encryption, login, keepalive |
| [video.md](video.md) | codec negotiation, H.264/H.265 frames, keyframes, FPS/quality, cursor |
| [resolution.md](resolution.md) | displays, change resolution, restore, virtual displays |
| [input.md](input.md) | mouse, keyboard (Legacy mode), Ctrl+Alt+Del, touch, clipboard |

## Verified against the real host (2026-11-21)

`spike/probe.py` against a Windows PC with an NVIDIA GPU (RustDesk 1.5.3,
`direct-server=Y`, password approval):

- The host speaks first over plain TCP: `Message.hash` (field 9) with a
  32-char salt and a 6-char challenge. 1-byte frame header, as specced.
- Login with `SHA256(SHA256(pw‖salt)‖challenge)` and `username` = the IP:
  `LoginResponse.peer_info` (hostname, 1 display 1920×1080, 11 modes).
- Asking for H.264 in `supported_decoding` gives `h264s` frames 0.37 s after
  login: Annex-B (`00 00 00 01 67…`, SPS in-band), ~28 fps (default 30 cap),
  ~12 KiB/frame, ~2.6 Mbit/s for an idle desktop.
- Echoing `TestDelay` unchanged keeps the session alive.
- Unrequested traffic to switch off or ignore: Opus `audio_frame` (~100/s),
  `cursor_data`, `cliprdr`, `misc.audio_format`, `misc.supported_encoding`.

## Second host: macOS (2026-11-21)

RustDesk 1.5.3 on a MacBook Air (Homebrew cask), direct IP, used as the
development host: login OK, 17 modes (native 2880×1864 and scaled), and the
host sends **H.265** even when the client prefers H.264 (its VideoToolbox
encoder is offered as HEVC; `PeerInfo.encoding` lists no h264). ~24 fps,
~2 Mbit/s. So the HEVC path is not optional. macOS needs Screen Recording and
Accessibility granted by hand once.

Resolution on a Mac host: `DisplayInfo.width/height` and `SwitchDisplay`
are **backing pixels** (3840×2486, `scale` 2.0), while `resolutions` and
`original_resolution` are **points** (1920×1243). Asking for 1440×932 is
confirmed as 2880×1864. Divide by the display's `scale` before comparing
(Windows always reports 1.0). Changing and restoring work, restore within
~1 s of disconnect.

## Host VRAM footprint

Windows `\GPU Process Memory(*)\Dedicated Usage`, sampled every 2 s with
`tools/vram.ps1` on the host:

| State | RustDesk 1.5.3 | Splashtop | Sunshine |
|---|---|---|---|
| Idle | 0 MB | 0 MB | 54 MB |
| 1080p H.264 session (~29 fps) | ~60 MB (NVENC) | not measured yet | — |

The GPU memory is taken when a session starts and released when it ends.

## What this means for the app

- **No crypto library needed**: direct IP is plaintext on stock 1.5.3. The VPN
  is the only protection; acceptable on a LAN or VPN; say so in the UI.
- **Video**: VideoToolbox H.264/H.265 only. The host falls back to VP9 if its
  hardware encoder fails; show an error rather than ship a VP9 decoder.
- **Resolution follows the client** works only for modes in the host's list.
  The Duo's 2670×1878 (1.42:1) and the outer display's aspect are not there:
  add them as custom modes to the Sunshine Virtual Display Driver, or pick the
  nearest mode and letterbox. Remember the original mode client-side too: if
  the host restarts mid-session, RustDesk's in-memory restore is lost.
- **Input**: absolute mouse moves from a client-side virtual cursor (what the
  official mobile app does), Legacy keyboard mode with Unicode `chr`,
  `ControlKey.CtrlAltDel` for the SAS, text clipboard plain UTF-8 (iOS peer).
