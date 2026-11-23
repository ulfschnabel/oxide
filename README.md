# Oxide

A modern, native client for [RustDesk](https://rustdesk.com) hosts on iPhone,
iPad and Mac, written in Swift and SwiftUI. It was first built for a foldable,
the iPhone Duo. On the App Store it's **Oxide Remote**.

**Oxide is a client only.** Every computer you control needs RustDesk installed
and running, with direct IP access turned on (RustDesk → Settings → Security).
Oxide connects to it directly, on your own network or over a VPN.

- **Native and light.** Hardware HEVC/H.264 decoding straight to the screen, no
  web views, no cross-platform runtime.
- **The remote screen fits your device.** The remote computer switches to the
  resolution that best fits this screen, and adapts as you rotate, fold or
  resize the window. It goes back to its own resolution when you disconnect.
- **Trackpad or touch.** Trackpad mode works like a laptop trackpad. Touch mode
  acts where you tap. Gestures for right-click, scroll and drag. Sticky
  ctrl/alt/win/shift, extra keys, hardware keyboard and mouse.
- **Zoom.** Pinch to zoom in up to 4×; in trackpad mode the view follows the
  pointer.
- **Stays connected.** The session survives a quick trip to another app, and
  reconnects by itself when the connection drops or you come back later.
- **Several computers at once.** Switch with a three-finger swipe, or split the
  screen to show two at once (stacked when upright). On a Mac each computer is a
  tab; on an iPad it can have a window of its own.
- **Keyboards and mice.** A hardware keyboard works like one plugged into the
  computer (physical keys, held keys), and every mouse button works.
- **Saved computers, on all your devices.** The list syncs through iCloud, and
  passwords through iCloud Keychain (end-to-end encrypted). Without iCloud
  everything stays on the device.

> Oxide is an independent project and is not affiliated with or endorsed by
> RustDesk or Purslane Ltd. "RustDesk" is their trademark.

## Requirements

Oxide connects **directly** to a computer running RustDesk, on your network or
over a VPN. It doesn't use RustDesk's rendezvous or relay servers. On the
remote computer:

1. Install RustDesk (tested with 1.5.3 on Windows and macOS).
2. Settings → Security → **Enable direct IP access** (port 21118).
3. Set a **permanent password**.

The direct-IP connection is **not encrypted**, so use it only on a network you
trust or over a VPN such as WireGuard or Tailscale.

## Building

Xcode 27+, iOS 26 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open Oxide.xcodeproj
```

The protocol and session logic live in the `OxideKit` Swift package, with tests:

```bash
cd Packages/OxideKit && swift test
```

`spike/fakehost.py` is a minimal fake RustDesk host. It logs in a client,
replays recorded video frames and answers resolution changes, so you can test
without a real host:

```bash
cd spike && uv run --with protobuf python fakehost.py --password devpass --port 21119
```

How Oxide speaks the protocol is documented in [docs/protocol](docs/protocol/README.md).

## License

Oxide is free software under the [GNU Affero General Public License v3](LICENSE).
It includes RustDesk's protocol definitions (`Packages/OxideKit/Protos/message.proto`,
from [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) 1.5.3), which are
part of RustDesk and licensed under the same terms. It uses
[SwiftProtobuf](https://github.com/apple/swift-protobuf) (Apache License 2.0).

Copyright (C) 2026 Ulf Schnabel
