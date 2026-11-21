# RustDesk video protocol: spec for a native client (RustDesk 1.5.3)

Source: RustDesk 1.5.3 source (github.com/rustdesk/rustdesk, tag `1.5.3`, commit 95cca3f). Paths below are relative to the repository root unless prefixed.
The `hwcodec` crate is an external git dependency (Cargo.lock:3890-3892, `rustdesk-org/hwcodec#ec38eba`). Paths in that crate are prefixed `hwcodec:`.
Proto file: `libs/base/protos/message.proto` (shortened to `proto`).

Transport framing, login and encryption are out of scope here. Everything below travels as `Message` (proto:1005) on the established session.

---

## 1. Codec negotiation

### 1.1 Messages
```
message SupportedDecoding {            // proto:656-674
  enum PreferCodec { Auto=0; VP9=1; H264=2; H265=3; VP8=4; AV1=5; }
  int32 ability_vp9 = 1;  int32 ability_h264 = 2;  int32 ability_h265 = 3;
  PreferCodec prefer = 4; int32 ability_vp8 = 5;  int32 ability_av1 = 6;
  CodecAbility i444 = 7;  Chroma prefer_chroma = 8;   // Chroma {I420=0; I444=1}
}
message CodecAbility { bool vp8=1; vp9=2; av1=3; h264=4; h265=5; }   // proto:109-115
message SupportedEncoding { bool h264=1; h265=2; vp8=3; av1=4; CodecAbility i444=5; } // proto:117-123
```
The `ability_*` fields are ints. The host only tests `> 0` (codec.rs:193-200), so send 1.

### 1.2 When the client sends it
- **At login:** `LoginRequest.option` (proto:73, an `OptionMessage`) with `OptionMessage.supported_decoding = 10` (proto:691). The stock client always fills it in (client.rs:3436).
  - The host reads it in `update_codec_on_login` (connection.rs:2745-2756).
  - If `option` or `supported_decoding` is absent, the host registers the client as **VP9-only** (`EncodingUpdate::NewOnlyVP9`, codec.rs:181-189).
- **Later:** `Misc.option` (proto:837) with an `OptionMessage` that carries `supported_decoding`. The host runs `Encoder::update(Update(id, q))` (connection.rs:4951-4953). The stock client re-sends it when a decoder fails (client.rs:4100-4119, 3902-3911).

### 1.3 What the host advertises
`PeerInfo.encoding` (proto:134) is set to `Encoder::supported_encoding()` (connection.rs:2138-2142):
- `vp8 = true` and `av1 = !32-bit`.
- `h264` / `h265` are true only if a HW RAM encoder or VRAM encoder exists (codec.rs:331-355).
- `i444` is `{vp9, av1}`.

The host pushes updates as `Misc.supported_encoding = 34` from a periodic timer when the usable set changes (connection.rs:1185, 5751-5775).

### 1.4 How the host picks (`Encoder::update`, codec.rs:171-325)
One codec is chosen **globally for all connected controllers**. Every connection's `SupportedDecoding` is stored in `PEER_DECODINGS` (codec.rs:42, 173-190).
- `h264_useable` = every peer has `ability_h264>0` AND (a VRAM H.264 encoder OR a HW RAM H.264 encoder exists) (codec.rs:197-235). H.265 works the same way.
- `vp8_useable` / `av1_useable` require every peer to support them (av1 is also disabled on 32-bit) (codec.rs:193-196, 1033-1037).
- **The preference** is the most frequent `prefer` among peers whose preference is usable. `VP9` always counts as usable (codec.rs:238-269).
- **The auto order:** H265 > H264 > AV1 (if `av1-test` option != "N", default on) > VP9. VP8 replaces VP9/AV1 if host RAM is 4 GB or less (codec.rs:271-291).
- **An explicit preference:** `prefer=H264` gives H.264 only if an HW encoder exists, otherwise auto. VP8/VP9/AV1 preferences are applied unconditionally (codec.rs:293-311).
- If the negotiated codec changes while streaming, the video service restarts with the new encoder (video_service.rs:772-779).

### 1.5 Can a client say "H.264/H.265 only"? What if the host has no HW encoder?
- **Protocol-wise, yes:** set `ability_vp9=0, ability_vp8=0, ability_av1=0, ability_h264=1, ability_h265=1, prefer=H265 (or H264)`.
- **The host does not honour `ability_vp9=0`.** VP9 is the unconditional floor. When neither H.264 nor H.265 is usable, `auto_codec` starts as VP9 (or AV1/VP8 when those are usable for all peers) and nothing checks `ability_vp9` (codec.rs:273-291). `prefer=VP9` is also always accepted (codec.rs:241).
- **No software H.264/H.265 encoder exists.** The HW RAM candidates on Windows are `h264_qsv`/`hevc_qsv` (Intel), `h264_nvenc`/`hevc_nvenc` (NVIDIA) and `h264_amf`/`hevc_amf` (AMD) (hwcodec:src/ffmpeg_ram/encode.rs:198-247). There is no libx264/openh264 (grep finds nothing in hwcodec:src, hwcodec:cpp). The `EncoderCfg` software options are only VPX (VP8/VP9) and AOM (AV1) (codec.rs:136-142).
- **Encoder failure also forces VP9:**
  - If HW encoder creation fails, the HW config is cleared and the codec is set to VP9 (codec.rs:145-166).
  - If `setup_encoder` fails, the service falls back to VP9 (video_service.rs:671-690).
  - After 3 encode failures (or a failure on the first frame for latency-free encoders), `encoder.disable()` clears the in-memory HW config and restarts (video_service.rs:1320-1340, hwcodec.rs:210-212, vram.rs `disable`).
  - The HW config stays cleared until the host process re-runs the hwcodec check (hwcodec.rs:655-680, 721-766).
- **So a client must handle `vp9s` (and in principle `av1s`/`vp8s` if it advertised them) as a fallback, or show an error.** Advertising `ability_av1=0, ability_vp8=0` limits the fallback to VP9 only.

### 1.6 Chroma
HW encoders never use I444 (`use_i444` returns false for HWRAM/VRAM, codec.rs:403-420). H.264/H.265 is always 4:2:0. Set `prefer_chroma=I420` and leave `i444` empty.

---

## 2. Windows + NVIDIA: when H.264/H.265 hardware encoding is on

**Build:** official Windows x64 builds use `--hwcodec` plus `--vram` (.github/workflows/flutter-build.yml:173, 337-338). Features are defined at Cargo.toml:30-31 and libs/scrap/Cargo.toml:26-27.

**Host config options** (`Config::get_option`, host side):

| Key | Const | Semantics | Default |
|---|---|---|---|
| `enable-hwcodec` | keys.rs:72 | `option2bool`: `enable-*` is true unless value is `"N"` (hbb_common config.rs:2924-2936) | **ON** |
| `enable-directx-capture` | keys.rs:87 | same rule | **ON** |
| `allow-d3d-render` | keys.rs:31 | `allow-*` is true only if `"Y"`. Affects decoding only (codec.rs:887-891) | off (not relevant to host) |
| `av1-test` | keys.rs:92 | `!= "N"` | on |

- **HW RAM path (`h264_nvenc`/`hevc_nvenc` via FFmpeg, system-memory NV12 input):** needs `enable-hwcodec` (codec.rs:850-860, 221-231) and a successful probe.
  - The probe is `start_check_process()`, which spawns `rustdesk --check-hwcodec-config` on startup (hwcodec.rs:721-766; called at server.rs:739, ipc.rs:1238). It test-encodes a 1280x720 frame with each candidate (hwcodec:src/ffmpeg_ram/encode.rs:297-330).
  - The result is cached in `_hwcodec` config, keyed by GPU signature (hwcodec.rs:523-537, 604-627).
- **VRAM path (D3D11 texture input, FFmpeg nvenc):** needs `enable-hwcodec` AND `enable-directx-capture` (codec.rs:862-880, 203-217). The capturer must not be in GDI fallback (vram.rs:219-224; video_service.rs:789-794).
  - Only `Driver::FFMPEG` entries are used (vram.rs:235-240).
  - If no HW RAM fallback exists, every display's adapter must support it (vram.rs:241-262).
- **Config selection order** in `get_encoder_config`: VRAM first, then HW RAM, then VPX/AOM (video_service.rs:1116-1172).
- **The user does not need to enable anything.** The defaults are on. "Hardware codec" can be switched off in host settings (`enable-hwcodec=N`), which kills H.264/H.265 entirely. A failing NVENC probe (old driver, no NVENC session available) also leaves only VP9/AV1. **UNVERIFIED:** the exact UI label/location of the setting.
- **NVENC encoder settings** (hwcodec:cpp/common/util.cpp:20-63, 105-125, 200-240):
  - no B-frames, `gop_size = INT_MAX`, CBR (`rc=cbr`, hwcodec.rs:246-252), low-delay flag, 1 slice.
  - **H.264 High profile / HEVC Main**, NV12.
  - Colour: **BT.601 (SMPTE170M) primaries/matrix/transfer, limited (MPEG) range**.

---

## 3. VideoFrame structure

```
message EncodedVideoFrame  { bytes data = 1; bool key = 2; int64 pts = 3; }   // proto:4-8
message EncodedVideoFrames { repeated EncodedVideoFrame frames = 1; }       // proto:10
message VideoFrame {                                                        // proto:25-36
  oneof union { EncodedVideoFrames vp9s=6; RGB rgb=7; YUV yuv=8;
                EncodedVideoFrames h264s=10; EncodedVideoFrames h265s=11;
                EncodedVideoFrames vp8s=12;  EncodedVideoFrames av1s=13; }
  int32 display = 14;      // index into PeerInfo.displays
}
Message.video_frame = 6 (proto:1010)
```

- **One `EncodedVideoFrame` per FFmpeg `AVPacket`.** The host appends every packet that one `avcodec_receive_packet` loop returns, so in practice there is one per message, but loop over `frames` anyway (hwcodec.rs:114-135; vram.rs `encode_to_message`; hwcodec:cpp/ffmpeg_vram/ffmpeg_vram_encode.cpp:357-385).
- **`key`** is `pkt->flags & AV_PKT_FLAG_KEY` (hwcodec:cpp/ffmpeg_ram/ffmpeg_ram_encode.cpp:361-362; ffmpeg_vram_encode.cpp:380).
- **`pts`** is milliseconds since the video service (re)started: `frame->pts = ms`, with time_base 1/1000 (video_service.rs:816-817; util.cpp:43). It **resets to ~0 on every service restart** ("SWITCH"). With no B-frames, decode order equals display order.
- **`display`** is set from the service's display index (video_service.rs:1307).
- **Bitstream is Annex-B, with parameter sets in-band** (inferred; high confidence):
  - Neither the encoder nor the decoder sets `AV_CODEC_FLAG_GLOBAL_HEADER` or extradata. The flags set are `LOW_DELAY` and a mis-placed `FLAG2_LOCAL_HEADER` in `flags` (hwcodec:cpp/common/util.cpp:44-45; grep for GLOBAL_HEADER/extradata finds nothing).
  - RustDesk's own decoder passes `data` straight to `avcodec_send_packet` with no extradata (hwcodec:cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp:169-181; ffmpeg_vram_decode.cpp:185-197). FFmpeg's h264/hevc decoders only accept that if the stream is Annex-B with SPS/PPS (HEVC: VPS/SPS/PPS) in-band.
  - The recorder muxes these packets into MP4 without extradata (hwcodec:cpp/mux/mux.cpp:110-150).
  - **UNVERIFIED in this tree:** that NVENC repeats SPS/PPS on *every* IDR. That is FFmpeg nvenc's behaviour (`repeatSPSPPS` when no GLOBAL_HEADER), but FFmpeg's source is not in this checkout.
  - The safe client approach is to treat parameter sets as present on every `key=true` frame.
- **VideoToolbox recipe:**
  1. Split `data` on start codes `00 00 01` / `00 00 00 01`.
  2. Collect NAL types 7/8 (H.264) or 32/33/34 (HEVC).
  3. Build `CMVideoFormatDescriptionCreateFromH264ParameterSets` / `...HEVCParameterSets`. Rebuild it whenever the parameter-set bytes change.
  4. Convert the remaining NALs to 4-byte length-prefixed AVCC and submit them as one CMSampleBuffer per `EncodedVideoFrame`.
- **Ignore `rgb` / `yuv`** (proto:12-18, 28-29). They are not produced by a desktop host. **UNVERIFIED** that they are never sent.

---

## 4. Keyframes / refresh

- **No periodic keyframes.** GOP = `i32::MAX` (hwcodec.rs:33, 74; vram.rs uses `MAX_GOP`; util.cpp:24-32). The exception is when the host records, where `keyframe_interval=Some(240)` (video_service.rs:1114-1115).
- **A keyframe comes only from a fresh encoder.** The encoder is recreated (the video service loop `bail!("SWITCH")`) on:
  - the client asking for a refresh (video_service.rs:760-771);
  - a negotiated codec change (772-779);
  - an i444 change (785-788);
  - a new subscriber joining the display ("switch due to new subscriber", 1290-1296);
  - a display geometry change (1382-1410);
  - VRAM-to-GDI fallback or DXGI access lost (789-794, 980-988);
  - an encoder failure (1320-1340);
  - a desktop switch (798-805).
- **How to request a refresh** (client.rs:3521-3537; ui_session_interface.rs:443-451):
  - `Misc.refresh_video_display = 31` (int32 display index). Use this for host version >= 1.2.4 (`MIN_VER_MULTI_UI_SESSION`, common.rs:65, 148-150).
  - Or `Misc.refresh_video = 10` with value `true`, which refreshes all displays.
  - Host handling: connection.rs:3933-3946 calls `refresh_video_display` (4595-4604), which sets `OPTION_REFRESH` on that video service.
- **When the stock client asks for a refresh:**
  - its 120-frame queue overflows on a non-key frame (io_loop.rs:1716-1728; client.rs:114);
  - a decode error (client.rs:4085-4098);
  - queue backlog during fps control (io_loop.rs:1638-1658).
- **A VT client should send `refresh_video_display`** after any `VTDecompressionSession` error or `kVTVideoDecoderBadDataErr`, after receiving a non-key frame with no format description, and after an app foreground/resume. After a refresh it should drop non-key frames until `key=true` arrives.

---

## 5. Flow control and quality

### 5.1 Frame acks
- **Without acks:** `LoginRequest.video_ack_required = 9` (proto:80). The host copies it at connection.rs:2858.
  - If it is false (the default; the stock client never sets it, grep finds no client use), the host counts a frame as "fetched" when the connection task dequeues it for socket write (connection.rs:1079-1084).
  - The capture loop waits up to 3 s for all subscribers to fetch the current frame before capturing the next one (video_service.rs:1009-1023, 147-152, 207-255).
  - **So without acks, backpressure is just the TCP send path.** Leave `video_ack_required=false`.
- **With acks:** if `video_ack_required=true`, the client must send `Misc.video_received = 12` (`true`) per frame (connection.rs:3949-3954). Without acks every frame then stalls up to 3 s, giving about 0.3 fps.

### 5.2 TestDelay (mandatory to echo)
```
message TestDelay { int64 time=1; bool from_client=2; uint32 last_delay=3; uint32 target_bitrate=4; } // proto:705-710
```
- The host sends one every 1 s if none is outstanding (connection.rs:504, 1187-1201).
- **The client must echo the identical message back** (stock: client.rs:4268-4274, which echoes when `!from_client`). The host uses the echo to compute network delay and adapt FPS/bitrate (connection.rs:3132-3147; video_qos.rs:8-46).
- **If the client never echoes:** after 2 s outstanding, FPS is halved per extra second, down to a floor of 5 fps (`MIN_AUTO_FPS`) (connection.rs:1203-1206; video_qos.rs:50-51, 600-630).
- **The connection is closed** ("Timeout") if nothing at all is received from the client for 30 s (connection.rs:505, 1188-1191). Any message resets `last_recv_time` (connection.rs:1033).

### 5.3 FPS
- **Host defaults:** start at `INIT_FPS=15` and ramp up to the per-user cap. The cap is `custom_fps` or 30, clamped 1..120 (video_qos.rs:47-51, 270-280, 417-424).
- **The client sets the cap with `OptionMessage.custom_fps = 11`**, at login or via `Misc.option` (connection.rs:4945-4950). The stock client also uses it as its own decode-speed-based auto-FPS (io_loop.rs:1557-1633).
- **With several viewers**, the effective fps is the minimum over all users (video_qos.rs:27-29).

### 5.4 Image quality
- **Preset:** `OptionMessage.image_quality = 1` (`ImageQuality {NotSet=0, Low=2, Balanced=3, Best=4}`, proto:649-654).
- **Custom:** `image_quality=NotSet` plus `custom_image_quality = 6` set to `(percent << 8)` (client.rs:3384-3397, 3545-3548).
- **Host mapping:** Best 1.5, Balanced 0.67, Low 0.5, custom `((v>>8)&0xFFF)*2/100`, clamped 0.2..40 (codec.rs:893-927; video_qos.rs:435-455; connection.rs:4926-4943).
- The ratio scales `base_bitrate(w,h)`, for example 2073 kbps at 1080p (codec.rs:929-971). NVENC changes quality live (`support_changing_quality` true except vaapi, hwcodec.rs:196-198).

---

## 6. Multi-monitor

- `PeerInfo.displays` (repeated `DisplayInfo {x,y,width,height,name,online,cursor_embedded,original_resolution,scale}`, proto:38-48, 129) and `PeerInfo.current_display` (proto:130).
- **The default is the host's primary display.** `display_idx = primary_display_idx` (connection.rs:2153-2163). The host subscribes the connection to that display's video service on login (connection.rs:2261-2291).
- **To switch, send `Misc.switch_display = 5`** with `SwitchDisplay{display=idx, width/height=0 or a desired resolution}` (ui_session_interface.rs:858-870).
  - The host subscribes to the new display's service and validates the index (connection.rs:4606-4652, 4654-4690).
  - On hosts at or above 1.2.4 it does not unsubscribe the old display unless the client version is below 1.2.4. The stock client follows with `CaptureDisplays` (connection.rs:4677-4681).
- **`Misc.capture_displays = 30`** `{repeated int32 add, sub, set}` (proto:617-621) changes which displays are streamed: `set` replaces, `add` adds, `sub` removes (connection.rs:3904-3909, 4709-4775).
- **Several displays can stream at once.** Demultiplex by `VideoFrame.display` and keep one decoder per display (as io_loop.rs:1709-1715 does).
- **Host-to-client display changes** arrive as `Misc.switch_display` carrying new `x,y,width,height,cursor_embedded,resolutions,original_resolution` (video_service.rs:1414-1460; client handling io_loop.rs:2332-2355).
- **LoginRequest.version matters.** The host gates behaviour on the client's `version` (connection.rs:4677-4681). Send a real version string, e.g. "1.5.3". **UNVERIFIED:** the full list of version gates.

---

## 7. Cursor

On Windows the cursor is **not embedded** in the video (`is_cursor_embedded()` is false on non-X11, libs/scrap/src/common/mod.rs:275-287), so the client draws it.

```
message CursorData { uint64 id=1; sint32 hotx=2; sint32 hoty=3; int32 width=4; int32 height=5; bytes colors=6; } // proto:317-326
message CursorPosition { sint32 x=1; sint32 y=2; }                                                         // proto:328-331
Message.cursor_data=12, cursor_position=13, uint64 cursor_id=14                                             // proto:1016-1018
```

- **`colors`** is **zstd-compressed RGBA8, top-down, `width*height*4` bytes** (compress: input_service.rs:551-565, hbb_common compress.rs:17).
  - Windows produces RGBA via a GetDIBits BI_BITFIELDS shuffle (windows.cc:488-530) or a BGR-to-RGB swap for mask cursors (windows.rs:451-530). Monochrome/XOR cursors may get a 1-px outline, which adds 2 to width/height and 1 to the hotspot (windows.rs:306-321).
  - The stock client limits sizes to 1..512 and requires the hotspot inside the image (io_loop.rs:3024-3062).
  - **UNVERIFIED:** whether alpha is straight or premultiplied (it appears straight).
- **`id`** is a content hash: xxh3 of (w,h,hotx,hoty,raw RGBA), masked to 53 bits (common.rs:159-168; input_service.rs:558).
  - The host sends `CursorData` the first time a shape appears for a connection, then only `cursor_id` (input_service.rs:139-153). **The client must cache shapes by id.**
  - If an id is unknown, send `Misc.request_cursor_data = 39` (uint64 id) and the host re-sends the shape (proto:868-874; connection.rs:4073-4083).
- **`CursorPosition`** is the host's global (virtual-desktop) cursor coordinate (input_service.rs:356-393). To place it on a display, subtract `DisplayInfo.x/y`.
  - Positions are not sent to the connection that moved the mouse in the last 300 ms (input_service.rs:369-378).
- **Subscription gates** (connection.rs:2266-2272, 4960-4975):
  - The cursor *shape* service needs keyboard permission or `show_remote_cursor`.
  - *Position* messages need `OptionMessage.show_remote_cursor = 3 = Yes`.

---

## 8. Other things a VideoToolbox decoder must handle

1. **Resolution change.** The host checks the display geometry about once a second. On a change it sends `Misc.switch_display` with the new size and restarts the encoder (video_service.rs:807-812, 1382-1410). The next frame is an IDR with new SPS, so rebuild the format description and session when the parameter sets differ.
2. **Codec switch mid-stream.** The `VideoFrame.union` variant can change (h264s, h265s, vp9s) after another viewer joins, a HW failure, or an option change (codec.rs:171-325; video_service.rs:772-779). Detect it per frame, as the stock client does (client.rs:2695-2696), and tear down and recreate the decoder.
3. **pts resets** on every encoder restart. Don't use it as a monotonic clock across restarts; use display-on-arrival for low latency.
4. **Rotation.** The VRAM encoder refuses rotated textures (`bail!("rotation not supported")`, vram.rs:110-114), which leads to an encode failure, then disable, then fallback. **UNVERIFIED:** how the RAM path handles rotated (portrait) displays. The client presumably just sees different width/height.
5. **Colour.** Signalled as BT.601 limited range (util.cpp:48-52). Use the VUI in the SPS or set YCbCr matrix ITU-R 601 when converting. NV12 output (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) works directly.
6. **Repeat frames.** When the screen is static the host may re-encode the last frame (static_refresh, video_service/static_refresh.rs:15-60; repeat logic video_service.rs:933-965). These are ordinary P-frames.
7. **Multi-viewer.** Another controller connecting forces a new encoder and keyframe (video_service.rs:1290-1296), and possibly a codec downgrade if that viewer lacks H.264/H.265.
8. **SupportedEncoding updates** (`Misc.supported_encoding`) tell you whether H.264/H.265 is currently usable. Surface it in the UI.
