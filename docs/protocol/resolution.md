# RustDesk 1.5.3 — Displays & Resolution Change Protocol (Windows host)

Source: RustDesk 1.5.3 source (github.com/rustdesk/rustdesk, tag `1.5.3`, commit 95cca3f). The message proto is at
`libs/base/protos/message.proto`, not in `hbb_common`. All paths below are relative to the repo root.
Anything marked **UNVERIFIED** was inferred and not confirmed in source.

---

## 1. How the client learns about the displays

### Messages
```proto
message DisplayInfo {            // message.proto:38-48
  sint32 x = 1; sint32 y = 2;     // virtual-desktop origin
  int32 width = 3; int32 height = 4;  // current mode, physical px on Windows
  string name = 5;                // Windows GDI device name, e.g. "\\.\DISPLAY1"
  bool online = 6;
  bool cursor_embedded = 7;       // always false in DisplayInfo (display_service.rs:874)
  Resolution original_resolution = 8;
  double scale = 9;               // always 1.0 on Windows (display_service.rs:852-861)
}
message PeerInfo {               // message.proto:125-140
  ... repeated DisplayInfo displays = 4; int32 current_display = 5;
  SupportedResolutions resolutions = 11;   // modes of current_display ONLY
  string platform_additions = 12;          // JSON, one level
}
message Resolution { int32 width = 1; int32 height = 2; }          // :593
message SupportedResolutions { repeated Resolution resolutions = 1; } // :603
```

### When it is sent
- **Login**: `LoginResponse.peer_info`. `displays` comes from `update_get_sync_displays_on_login()`
  (connection.rs:2148-2176, display_service.rs:895-917). `current_display` is the primary display
  (`get_primary_2`, display_service.rs:929). `resolutions` holds the mode list of
  `displays[current_display]` only (connection.rs:2164-2174).
- **Later**: the display service polls every 300 ms (display_service.rs:707-733). When the list changes it
  broadcasts a bare `Message.peer_info` holding only `displays`, `current_display=0`, and
  `platform_additions` if installed (`displays_to_msg`, display_service.rs:635-653). That message has **no**
  `resolutions`. The client takes `displays` and `platform_additions` from it
  (client/io_loop.rs:2568-2571).
- The mode list for another display arrives in `SwitchDisplay.resolutions` (see §5).

### `original_resolution`
`get_original_resolution()` (display_service.rs:736-778):
- If RustDesk changed this display during the current "session epoch", it is the **pre-change** mode
  recorded in `CHANGED_RESOLUTIONS`.
- Otherwise it is the current mode.
- For a RustDesk-IDD virtual display it is `0x0` (dead path in 1.5.3, see §4). The Flutter client reads
  `0` as "virtual display, any resolution allowed" and `-1` as "unset" (flutter/lib/models/model.dart:4451-4495).

### Where the mode list comes from (Windows)
`platform::windows::resolutions(name)` (src/platform/windows.rs:3093-3115):
- Loops `EnumDisplaySettingsW(device, i, &dm)` for i = 0.. until it returns 0.
- Collects `(dmPelsWidth, dmPelsHeight)` and removes duplicates. Refresh rate, bpp and orientation are
  dropped.
- Order is the driver's enumeration order, not sorted.
- (`dm.dmSize` is left 0 here; it works in practice. **UNVERIFIED**: why Windows accepts it.)
- **UNVERIFIED**: on a rotated (portrait) monitor, it is not confirmed whether the modes come back in native
  (landscape) or rotated dimensions.

### `platform_additions` keys that matter
From `virtual_display_manager::get_platform_additions()` (virtual_display_manager.rs:45-71). They are
present only if the RustDesk service is running:
- `idd_impl`: `"amyuni_idd"` in 1.5.3.
- `amyuni_virtual_displays`: the count, present when > 0.

The client also uses `is_installed` and `platform == "Windows"` to decide whether virtual displays are
supported (client/io_loop.rs:110-124).

---

## 2. Change-resolution message

### Wire format
Wire format is `Message.misc`:
```proto
message DisplayResolution { int32 display = 1; Resolution resolution = 2; }   // message.proto:598
Misc.change_display_resolution = 36;   // use this (peer >= 1.2.4)
Misc.change_resolution = 24;           // deprecated; applies to the connection's current display
```
- The client picks field 36 when the peer version is 1.2.4 or later (ui_session_interface.rs:1596-1615,
  common.rs:65,148).
- `display` is the index into `PeerInfo.displays`.
- **Implicit form**: `Misc.switch_display` with non-zero `width`/`height`. After the switch the host also
  calls `change_resolution(None, {w,h})` on the new display (connection.rs:4605-4623).

### Host handling
Dispatch is at connection.rs:4015-4026. The message is ignored for view-camera sessions. The handler is
`Connection::change_resolution` (connection.rs:4830-4880):
1. **Permission gate**: does nothing unless `self.keyboard` is true (connection.rs:4831).
   - `keyboard` comes from the `enable-keyboard` option or the control-permissions override
     (connection.rs:594, 2713-2744; keys.rs:38).
   - It is forced false for file-transfer, terminal and view-camera sessions (connection.rs:2198, 2222, 2229).
   - The permission can be revoked at runtime (connection.rs:806-807). The client sees it through
     `PermissionInfo{Keyboard}`.
   - No other option controls resolution changes. `keys.rs` has no option containing "resolution".
2. It looks up `try_get_displays()[display]`. Without `display` it uses `self.display_idx`. An index out of
   range is silently ignored.
3. RustDesk-IDD virtual display: it calls `update_monitor_modes` (any mode) and returns. This is dead in
   1.5.3 (§4).
4. It records `(original=current mode, changed=req)` in `CHANGED_RESOLUTIONS[name]`
   (display_service.rs:576-588).
   - Only the **first** change per display name stores `original`. Later changes only update `changed`.
   - The map is global, not per connection.
   - Amyuni virtual displays are **not** recorded (connection.rs:4848-4851).
5. `platform::change_resolution(name, w, h)` (platform/mod.rs:96-110):
   - If the current mode is already `w×h` it does nothing.
   - Otherwise it calls `ChangeDisplaySettingsExW(device, {dmPelsWidth, dmPelsHeight, dmFields=DM_PELSWIDTH|DM_PELSHEIGHT}, NULL, CDS_UPDATEREGISTRY|CDS_GLOBAL|CDS_RESET, NULL)`
     (windows.rs:3137-3164).

### A mode that is not in the list
- There is **no nearest-mode logic and no validation** against the list.
- Windows/driver decide. Normally the result is `DISP_CHANGE_BADMODE` and the request is rejected. The host
  only logs it: "Failed to change resolution ..." (connection.rs:4870-4877).
- **Nothing is sent back to the client.** The only feedback is the lack of a `SwitchDisplay`/`PeerInfo` with
  the new size.
- The CHANGED_RESOLUTIONS record is written even when the call fails. This is harmless, because restore is a
  no-op when the current mode equals the original.
- No refresh rate or bpp is passed, so Windows picks the refresh rate. **UNVERIFIED** which one: the
  registry default or the highest.
- No orientation is passed. A portrait request such as 1080×2400 on a landscape monitor fails unless the
  driver lists that WxH. RustDesk never rotates a display: `grep DISPLAYORIENTATION` finds nothing.

### What a client must do
- Pick a `(w,h)` exactly from `SupportedResolutions` for that display.
- Send `change_display_resolution{display, resolution}`.
- Confirm success by waiting for `SwitchDisplay`/`PeerInfo` with the new width and height. The Flutter client
  waits 3 s (remote_toolbar.dart:2401).

---

## 3. Restore behaviour

### Automatic restore
- It is automatic, in `AuthedConnID::drop` (connection.rs:7076-7110).
- After the connection is removed from `AUTHED_CONNS`, the host counts the remaining connections with
  `conn_type == Remote`. If the count is 0 it calls `display_service::restore_resolutions()`, then
  `virtual_display_manager::reset_all()` (Windows).
- Restore happens only when the **last remote-control connection** closes. File-transfer, view-camera and
  terminal connections do not hold it open.
- It applies to **all** recorded displays at once: it sets each one back to `original`, then clears the map
  (display_service.rs:591-607).
- There is no per-display restore while other clients are still connected.

### Configuration
- There is no option to disable or tune it (no key in `libs/base/src/config/keys.rs`).
- A client can restore one display early by sending `change_display_resolution` with
  `display.original_resolution`.

### Client crash or network drop
- If the TCP connection closes, the Connection ends and restore runs.
- If the network fails silently, the host closes the connection after 30 s without any received data
  (`test_delay_timer`, connection.rs:1187-1190, `SEC30` at :505). Restore runs then.
- So restore happens up to about 30 s late.

### Host crash
- `CHANGED_RESOLUTIONS` exists only in memory in the server process.
- `CDS_UPDATEREGISTRY` writes the new mode to the registry. If the RustDesk server process crashes, is
  killed or restarted, or the PC reboots during a session, the changed resolution **stays permanently** and
  nobody restores it (inferred from the code; **UNVERIFIED** on a real host).

### Official client re-applies on reconnect
- It saves the last custom resolution per peer and per display: `PeerConfig.custom_resolutions`
  (hbb_common/src/config.rs:383; client.rs:3623-3645; ui_session_interface.rs:1546-1574).
- It re-sends that resolution on the next login (`try_change_init_resolution`,
  ui_session_interface.rs:1589-1594, 1843).
- It also sends it in `SwitchDisplay.width/height` when switching displays (ui_session_interface.rs:858-871).

---

## 4. Virtual displays on Windows

### Driver in 1.5.3
- `IDD_IMPL` is **hard-coded to `amyuni_idd`** (virtual_display_manager.rs:9).
- All RustDesk-IDD code is unreachable: `rustdesk_idd::*`, `plug_in_index_modes`,
  `change_resolution_if_is_virtual_display` → `update_monitor_modes`, which supports arbitrary modes.
- `libs/virtual_display` is unused on this path.

### Message
`Misc.toggle_virtual_display = ToggleVirtualDisplay{int32 display=1; bool on=2}` (message.proto:623).
Handling is at connection.rs:3911-3915 and 4780-4827:
- It works on Windows only, outside view-camera sessions.
- It does **not** check the `keyboard` permission. (**UNVERIFIED**: whether some other gate applies higher
  up.)
- `on=true` requires Windows 10 2004 or later (build 19041; virtual_display_manager.rs:26-35).
  - It then calls `amyuni_idd::plug_in_monitor()`. **The `display` index and the mode list are ignored**
    (virtual_display_manager.rs:73-79).
  - If the driver is missing, it installs it (usbmmidd_v2 via SetupAPI; :489-525). The installer ships
    `usbmmidd_v2` (flutter-build.yml:341-345).
  - Maximum of 4 monitors (:414, 655-657).
- `on=false` calls `plug_out_monitor(display, false, force_one=true)`, which removes one amyuni monitor
  (:666-727).
- Errors come back as a `MessageBox`: `"idd_not_support_under_win10_2004_tip"` or "Failed to plug in
  virtual display: …".
- The official client sends `toggle_virtual_display{on:true}` automatically after the first video frame.
  It does this for each index in the peer option `virtual-display`, and only when the peer supports
  virtual displays (client/io_loop.rs:1479-1500, 1704).

### Resolutions
- A new amyuni monitor is forced to **1920×1080** right after it is plugged in
  (`try_reset_resolution_on_first_plug_in`, :596-627).
- After that it behaves like any other display. Its modes come from the usbmmidd driver's **fixed** mode
  list through EnumDisplaySettings, and `change_display_resolution` uses the same
  ChangeDisplaySettingsExW path.
- **2670×1878 is only possible if the amyuni driver lists it. That is very unlikely.**
  **UNVERIFIED**: the driver's mode list could not be checked, because it is a closed binary downloaded
  at build time.
- Amyuni resolution changes are not recorded for restore (connection.rs:4848-4851).
- When the last remote connection closes, `reset_all()` turns off privacy mode and unplugs **all** amyuni
  monitors with `force_all=true` (virtual_display_manager.rs:527-532). That includes monitors that other
  software added.

### Automatic headless display
`try_get_displays_add_amyuni_headless()` at login (display_service.rs:976-1029) plugs in an amyuni display
only when all of these hold:
- RustDesk is installed.
- Windows build is 19041 or later.
- There are no displays, or only one display with every mode ≤ 1024 px.

### Reliability
- The messages are simple, but the design is lossy: the index is ignored, the mode list is ignored, the
  monitor count is tracked inexactly (comment at :414-421), and other software's monitors get removed on
  disconnect.
- Treat it as best-effort. **Not usable for arbitrary resolutions in 1.5.3.**

### Sunshine Virtual Display Driver on the host
- **RustDesk treats it as an ordinary physical display.** It shows up in `PeerInfo.displays` under its own
  `\\.\DISPLAYn` name.
  - Its modes are whatever the driver lists in EnumDisplaySettings.
  - Changes to it are recorded and restored like a real monitor.
  - `amyuni_idd::is_my_display` matches only the device string `"USB Mobile Monitor Virtual Display"`, so
    the two drivers are not confused (virtual_display_manager.rs:7, 734-738).
- **Opportunity**: SudoVDA / MTT VDD can expose custom modes from their own configuration. If 2670×1878 and
  the outer-screen mode are added there, they appear in `SupportedResolutions` and the stock host can
  switch to them. **UNVERIFIED**: the exact configuration mechanism depends on the VDD version (e.g.
  `vdd_settings.xml` plus a driver reload).
- **Risks**:
  - If Sunshine/Apollo is streaming, or holds its own "restore display on disconnect" state, the two
    restore mechanisms can overwrite each other. RustDesk restores to whatever was current at its first
    change.
  - If the Sunshine VDD is attached and larger than 1024 px, RustDesk will never auto-add the amyuni
    headless display.
  - If an amyuni display is plugged in, `reset_all(force_all)` only touches amyuni monitors. It does not
    touch the VDD.

---

## 5. How the host tells the client about a change

### Detection
The video service for display N detects the change in three ways:
- A forced check every 1 s (`try_broadcast_display_changed(..., false)`, video_service.rs:807-812).
- A check on capture errors such as DXGI ACCESS_LOST (:965-995).
- A check on `OPTION_REFRESH` (:762-770).

`check_display_changed` compares the capturer's origin and size with the synced `DisplayInfo`
(display_service.rs:546-574).

### Notification
On a mismatch, `make_display_changed_msg` (video_service.rs:1414-1461) broadcasts:
```proto
Misc.switch_display = SwitchDisplay {   // message.proto:605-615
  display, x, y, width, height,        // new geometry
  cursor_embedded,
  resolutions = modes of THIS display,
  original_resolution                   // pre-change mode while a change is recorded
}
```
- It is also queued as a snapshot for new subscribers (:1400-1406).
- The display service separately sends a `PeerInfo` with the full updated `displays` list within about
  300 ms (§1). If other monitors moved, their new x/y arrive there.
- The host also replies with `SwitchDisplay` after a client `SwitchDisplay` (connection.rs:4625-4635).

### Video stream
- After the broadcast the service fails with `bail!("SWITCH")` (:1408). The service loop restarts `run()`
  after 30 ms, doubling on rapid repeat errors up to 1 s (service.rs:44-45, 294-329).
- That creates a new capturer and encoder at the new size. The new encoder starts with a keyframe
  (**UNVERIFIED** explicitly; this is standard for every encoder RustDesk uses).
- `VideoFrame` has no size field (message.proto:24-36, only `display`). The new size is visible from
  `SwitchDisplay` and in the bitstream.

### Client reaction
- It resets that display's decoder thread (`MediaData::Reset` → `handler.reset`, client/io_loop.rs:2332-2336,
  client.rs:4124-4127).
- If w and h are greater than 0 it updates the display rect (io_loop.rs:2345-2354).
- It calls `set_custom_resolution` (ui_session_interface.rs:1576-1579).
- A native client should do the same: on `SwitchDisplay`, drop or reinit its VideoToolbox session for that
  display, wait for the next keyframe, and update its coordinate mapping (mouse x/y are in the host's virtual
  desktop pixels).

---

## 6. Official client policy ("match local resolution")

### Desktop (`_ResolutionsMenu`, flutter/lib/desktop/widgets/remote_toolbar.dart:2218-2545)
- The menu is shown only if the keyboard permission is granted, and either the display is virtual or more
  than one mode is listed (:2277-2281).
- **"Fit local"** (`_getBestFitResolution`, :2515-2532) takes the local main display's `w×h` (:2339-2360).
  - On a virtual display (original=0) it sends exactly that.
  - Otherwise it looks for an **exact** w×h match in `pi.resolutions`. With no exact match the button is
    hidden.
  - **There is no aspect-ratio or nearest-mode heuristic in the official client.**
- **"Original"** sends `original_resolution`. It is shown only if that mode is in the list (:2422-2443).
- The custom W×H field is offered only for virtual displays (:2463-2487).

### Mobile
`getResolutionMenu` (flutter/lib/mobile/pages/remote_page.dart:1527-1567) is a plain picker over
`pi.resolutions`. There is no automatic matching. On-device scaling is done client-side.

### Consequence
The aspect-first nearest-mode choice has to be designed by us. Suggested rule; this is **not** RustDesk
behaviour:
1. Use only exact entries from `SupportedResolutions`.
2. Minimise the aspect error `|ln(w/h) − ln(W/H)|`.
3. Among modes within about 2% of the best aspect, prefer the smallest mode that is at least the client's
   pixel size; otherwise take the largest.
4. Never send a mode that is not in the list.

What Oxide does (`ResolutionPicker`): among modes within about 35% of the screen's aspect, it minimises the
aspect error plus a quarter of the size error. If none is that close, for example an upright phone against
a Windows host, which lists modes for the current orientation only, the picture is letterboxed anyway. It
then picks the mode whose fitted scale is closest to the target (`min(W/w, H/h)` near 1, so in portrait the
width matches), with a small preference for squarer modes. It doesn't go below 1024×720 if the host lists
anything that size.

### Resolution before the first picture
The client can't ask for a resolution before the stream starts. `OptionMessage.custom_resolution` (field
13) is removed in 1.5.3, and the host subscribes the connection to video as soon as it sends the
`LoginResponse` (connection.rs:2231, `try_sub_monitor_services`). So the first frames are always at the
host's old resolution.

Oxide asks for its mode right after login and keeps the picture back (`PictureHold`), showing
"Connecting…" until one of these happens:
- the host confirms the new size with a `SwitchDisplay`;
- no change is needed;
- 4 s pass, longer than one request's 3 s confirm timeout.

It then flushes the display layer and sends `Misc.refresh_video` for a key frame. A reconnect within the
host's 30 s session window usually needs no change, because the host restores resolutions only when the
last connection closes.

---

## 7. Risks

- **Local user**: `CDS_GLOBAL|CDS_UPDATEREGISTRY` changes the physical display mode for everyone, and the
  change persists. A person at the PC sees it immediately. Privacy mode is not involved.
- **Persistence on a crash**: see §3. A host-side crash or reboot leaves the mode changed for good.
  Mitigation: the client stores the original mode itself and re-sends `original_resolution` on its next
  connect.
- **Multi-monitor**:
  - The change applies to the named display only.
  - Windows may move adjacent monitors when the size changes (**UNVERIFIED**). The new x/y arrive via
    `PeerInfo`, so remap input.
  - `change_resolution` without `display` targets the connection's current display.
  - Several clients share one global restore map. The first original wins, and restore waits for the last
    remote client to leave.
- **Orientation and portrait**: RustDesk never changes orientation. A portrait-rotated iPhone cannot get a
  portrait host mode unless the display (e.g. a VDD) lists a WxH with H > W.
- **Refresh rate**: it is not specified, so it may drop to 60 Hz or change (**UNVERIFIED**).
- **HDR**: not handled. Changing the mode through the legacy `ChangeDisplaySettingsEx` API may toggle or
  reset HDR or advanced colour on some GPUs (**UNVERIFIED**).
- **DPI scaling**: not touched by RustDesk. Windows may apply a different per-monitor scale after the mode
  changes (e.g. the recommended scale), and that can rearrange the local desktop (**UNVERIFIED**).
  `DisplayInfo.scale` stays 1.0 on Windows, so the protocol always uses physical pixels.
- **Silent failure**: a rejected mode produces no error message. Use a timeout and keep the current stream.
- **Rate**: every change rebuilds the capturer and encoder, which causes a stall and a keyframe. Debounce
  fold and rotate events (e.g. by 500 ms or more).
- **Amyuni `reset_all(force_all)`** on the last disconnect can remove virtual monitors that RustDesk did not
  create.
