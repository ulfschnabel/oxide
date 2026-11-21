# RustDesk 1.5.3 — Input & Clipboard protocol spec (client → Windows host)

Source: RustDesk 1.5.3 source (github.com/rustdesk/rustdesk, tag `1.5.3`, commit 95cca3f).
Paths below are relative to that root. `proto` = `libs/base/protos/message.proto`.
All messages go inside the top-level `Message.union` (proto:1005): `mouse_event = 10`, `key_event = 15`,
`clipboard = 16`, `cliprdr = 20` (files, out of scope), `pointer_device_event = 26`, `multi_clipboards = 28`
(proto:1014-1032). Permissions come back in `Misc.permission_info = 6` (proto:836).

---

## 1. MouseEvent

```proto
message MouseEvent {            // proto:197
  int32  mask = 1;
  sint32 x = 2;
  sint32 y = 3;
  repeated ControlKey modifiers = 4;
}
```

### 1.1 `mask` encoding (src/common.rs:67-92)

`mask = (button << 3) | type`. Host decodes `type = mask & 0x7`, `buttons = mask >> 3`
(src/server/input_service.rs:1290-1291).

| type | value | x,y meaning |
|---|---|---|
| MOVE | 0 | absolute host position |
| DOWN | 1 | ignored by injection (Flutter sends 0,0) |
| UP | 2 | ignored by injection |
| WHEEL | 3 | scroll notches |
| TRACKPAD | 4 | scroll in raw wheel units (smooth) |
| MOVE_RELATIVE | 5 | delta dx,dy (host ≥ 1.4.5) |

| button | value | mask for DOWN / UP |
|---|---|---|
| LEFT | 0x01 | 0x09 / 0x0A |
| RIGHT | 0x02 | 0x11 / 0x12 |
| WHEEL (middle) | 0x04 | 0x21 / 0x22 |
| BACK | 0x08 | 0x41 / 0x42 |
| FORWARD | 0x10 | 0x81 / 0x82 |

- The host matches the button with `match buttons { MOUSE_BUTTON_LEFT => …}`, which is an exact equality check. So send **one button per event**, because a combined mask is silently ignored (input_service.rs:1377-1412).
- DOWN/UP do **not** move the cursor. Only MOVE/MOVE_RELATIVE position it (input_service.rs:1318-1376). Flutter always sends `x=y=0` on down/up (flutter/lib/models/input_model.dart:2196-2202), so you send a MOVE first and then DOWN/UP.
- `modifiers` on a **DOWN** event are pressed before the click and released after it (Ctrl+click, Shift+click). Before that, `fix_modifiers` releases any host-held Shift/Ctrl/Alt/Win that is *not* listed (input_service.rs:1297-1316, 1466-1469, 1055-1080).

### 1.2 Coordinate space (absolute MOVE)

- On Windows the coordinates are **physical pixels in the Windows virtual-desktop space**. Enigo maps them with `SM_XVIRTUALSCREEN/SM_CXVIRTUALSCREEN` → `MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK` (libs/enigo/src/win/win_impl.rs:139-163). The process is per-monitor DPI aware (`SetProcessDpiAwareness(2)`, src/main.rs:27).
- It is the same space as `DisplayInfo{x,y,width,height}` (proto:38-48) and `SwitchDisplay{x,y,width,height}` (proto:605-615). Multi-display: `host_x = display.x + px_in_display`, `host_y = display.y + py_in_display`. The display origin can be negative.
- The Flutter client uses `ffiModel.rect = Rect(display.x, display.y, w, h)` (flutter/lib/models/model.dart:4605, union for "all displays" at 190-210). It converts view → host with `(viewX - canvasX)/scale + displayOriginX` (model.dart:3327-3333) and clamps to `[rect.left, rect.left+width]`. For a Windows peer it does not subtract 1, so that edge snapping works (input_model.dart:2390-2408).
- The host reports its cursor position as `Message.cursor_position {sint32 x,y}` (proto:328) in the same space. It is sent on change to every connection *except* the one that injected input within the last 300 ms (input_service.rs:356-393). Flutter overwrites its virtual cursor with it (model.dart:3815-3828).

### 1.3 Relative movement

- `MOUSE_TYPE_MOVE_RELATIVE = 5`, with `x,y` as deltas. The host clamps them to ±10000 and calls `en.mouse_move_relative` (input_service.rs:1351-1376). On Windows that is `mouse_event(MOUSEEVENTF_MOVE)` without ABSOLUTE (win_impl.rs:165-167). UNVERIFIED: it is therefore subject to Windows pointer acceleration ("Enhance pointer precision").
- The Flutter client gates it on peer version ≥ 1.4.5 (flutter/lib/consts.dart:309, relative_mouse_model.dart:204). The server needs no mode switch: a MOVE (type 0) simply clears the relative flag (input_service.rs:1320). The `relative_mouse_mode` JSON marker is client-local and is never put on the wire (src/flutter_ffi.rs:1995-2052).

### 1.4 Scroll units and direction (Windows host, input_service.rs:1413-1463)

The host computes `x' = -evt.x`, `y' = evt.y` (on Windows y is not negated), then:

- **WHEEL (3):** `x', y'` are multiplied by `WHEEL_DELTA` (120) and sent as `MOUSEEVENTF_WHEEL` (y) and `MOUSEEVENTF_HWHEEL` (x) (win_impl.rs:227-233). So **1 unit = 1 notch**.
  - `y = +1` scrolls up (content moves down). `y = -1` scrolls down.
  - `x = -1` scrolls right. `x = +1` scrolls left.
  - Flutter desktop maps `scrollDelta.dy > 0` (scroll down) → `y = -1`, and `dx > 0` → `x = -1` (input_model.dart:1975-2020). Flutter mobile three-finger drag sends `y = ±1` (flutter/lib/common/widgets/remote_input.dart:520-531, input_model.dart:1417-1423).
- **TRACKPAD (4):** the same signs, but **no ×120**, so the value is in raw wheel units and gives smooth/high-resolution scrolling. Flutter sends the finger pan delta in logical px × speed (default 1.0; ×2.5 when the client is a Mac and the peer is Windows) (input_model.dart:1663-1696, consts.dart:295).
  - Natural mapping: `x = finger_dx`, `y = finger_dy` (fingers moving up → negative y → scroll down → content follows the fingers).
- The client option `reverse_mouse_wheel = "Y"` negates both axes on the client (src/ui_session_interface.rs:1229-1263, src/platform/mobile_wheel.rs:1-7).

### 1.5 How the Flutter mobile client does trackpad vs touch

The Flutter mobile client always sends **absolute MOVE positions that it computes itself**. It keeps a virtual cursor `_x,_y` in host coordinates. It never uses relative messages except in the optional relative/joystick mode.

- **Mouse ("trackpad") mode** (`touchMode == false`):
  - One-finger pan: `cursorModel.updatePan(delta)` → `_x += dx/scale`, clamped to the display rect and the visible rect (it also pans the canvas) → `moveMouse(_x,_y)` → MOVE (model.dart:3362-3446, input_model.dart:1485-1493).
  - Tap → `tap(left)` = DOWN then UP, at the current cursor (remote_input.dart:178-195).
  - Double-tap → two taps (211-230).
  - Two-finger tap → right click (309-323).
  - Long press → right click (264-286).
  - Hold-drag → left DOWN, pan, UP (325-353).
  - Two-finger pinch/pan → **local** canvas zoom/pan only, nothing is sent (489-495).
  - Three-finger vertical drag → WHEEL ±1 (520-531).
- **Touch mode** (`touchMode == true`):
  - Tap → MOVE to the finger's host position, then DOWN/UP (155-176, model.dart:3291-3302).
  - One-finger pan → DOWN at the start, then MOVEs that follow the finger, then UP (a drag) (355-439, model.dart:3424-3489).
  - Long press → right click (264-286).
- `MouseEvent.modifiers` is filled from the client-side Alt/Ctrl/Shift/Cmd toggles (src/client.rs:4316-4352).
- The JSON bridge `session_send_mouse` turns `type`/`buttons` strings into the mask (flutter_ffi.rs:2066-2090).

---

## 2. KeyEvent

```proto
message KeyEvent {                     // proto:298
  bool down = 1;                       // key state
  bool press = 2;                      // click = down+up
  oneof union {
    ControlKey control_key = 3;
    uint32 chr = 4;                    // meaning depends on mode (see below)
    uint32 unicode = 5;
    string seq = 6;
    uint32 win2win_hotkey = 7;         // hi16 = VK, lo16 = unicode
  }
  repeated ControlKey modifiers = 8;
  KeyboardMode mode = 9;               // Legacy=0, Map=1, Translate=2, Auto=3 (proto:204)
}
```

### 2.1 Host dispatch (Windows)

- Gate: `peer_keyboard_enabled()` must be true (src/server/connection.rs:3337, 2344-2346).
- On Windows `is_press = me.press` (connection.rs:3363-3367).
  - `press=true` with `control_key`/`chr`: the input thread calls `handle_key` twice, first with `down=true` and then with `down=false` (connection.rs:3377-3386, 1276-1287).
  - `press=true` with `unicode`/`seq`: called once with the `down` you sent (connection.rs:3379-3381).
  - `press=false`: called once with your `down`.
- Then `handle_key_` dispatches on **each event's own `mode`**, and any value other than Map/Translate falls to Legacy (input_service.rs:2529-2547). Modes can therefore be **mixed per message**. Flutter itself sends soft-keyboard and toolbar keys as Legacy even when the session mode is Map (ui_session_interface.rs:1127-1166).

### 2.2 Modes

- **Legacy (0)** (input_service.rs:2208-2251). This is the only mode that honours `modifiers`, `control_key`, `CtrlAltDel` and `LockScreen`.
  - `sync_modifiers`: on `down`, it releases host-held Shift/Ctrl/Alt/Win that are not in `modifiers` (fix_modifiers, 1055-1080). Then it presses the listed modifiers that are not held and releases them again at the end of this same call (1807-1833, 2249-2250).
  - `control_key` → VK via `KEY_MAP` (2639-2715), key down/up per `down`.
  - `chr` = **a Unicode code point** (not a scancode) (1850-1904).
    - Without Ctrl/Alt/Win in `modifiers`, on down it does `key_sequence(char)`, i.e. `SendInput KEYEVENTF_UNICODE`. This is independent of the host keyboard layout, and Shift is irrelevant (1878-1886, win_impl.rs:245-268, 390-396).
    - With Ctrl/Alt/Win (`has_hotkey_modifiers`, 1771-1789), it does `Key::Layout(c)`: `VkKeyScanExW` on the foreground window's layout, real VK down/up, and it adds Shift/Ctrl/Alt if the layout needs them (win_impl.rs:275-307, 492-503). If there is no mapping, it falls back to unicode.
  - `unicode` → `key_sequence` (1906-1925).
  - `seq` → `key_sequence(string)`, one KEYEVENTF_UNICODE down/up per UTF-16 unit. Surrogate pairs are sent as downs only (1927-1942, win_impl.rs:257-266).
- **Map (1)**: `chr` = **Windows set-1 scancode** of the physical key, with extended keys as `0xE0xx`, injected as a raw scancode per `down` (input_service.rs:1723-1735, 1621-1642). `modifiers` are ignored, so you send modifier keys as their own scancodes. The Flutter iOS client builds it from the USB-HID usage via `rdev::usb_hid_code_to_win_scancode` (src/keyboard.rs:1399-1401, 1349-1413). It needs a peer ≥ 1.2.0 that is not Android (src/common.rs:2059-2076).
- **Translate (2)** (input_service.rs:2262-2387):
  - `seq` → per char `rdev::simulate_unicode`, after releasing Shift. If Ctrl/Alt/Win is held on the host it uses `simulate_char` (layout key) instead.
  - `chr` → if `chr>>16 == 0` it is a scancode, otherwise the high word is a VK (2253-2260).
  - `unicode` is ignored, and **`control_key` is not handled** (falls to the "Unreachable" log). So Translate cannot do Ctrl+Alt+Del or arrow keys by ControlKey.
- **Auto (3)**: client-side only. It is not handled by the host, so it falls to Legacy.

**Recommendation for iOS text plus special keys: Legacy.** iOS delivers characters, Legacy injects characters as Unicode, and it supports ControlKey plus a modifier list. For a hardware keyboard you can optionally use Map: UIKey.keyCode is a HID usage → Windows scancode, which gives true key-down/up and games/shortcut fidelity.

### 2.3 Recipes (all with `mode = Legacy`)

| Action | KeyEvent |
|---|---|
| Typed "é", "ü", any BMP char | `chr = 0x00E9` / `0x00FC`, `press = true`. Mirrors Flutter mobile `inputChar` → `input_key(name)` → `Key::_Raw(char)` (flutter/lib/mobile/pages/remote_page.dart:430-440, ui_session_interface.rs:893-912) |
| Multi-char insert / paste / emoji | `seq = "text"` (no down/press needed), as in `input_string` (ui_session_interface.rs:914-920, remote_page.dart:366-367) |
| Enter | `control_key = Return (27)`, `press = true` |
| Backspace | `Backspace (2)`, press. iOS soft-keyboard deletions are sent as VK_BACK (remote_page.dart:361-363) |
| Tab / Esc | `Tab (31)` / `Escape (8)`, press |
| Arrows | `LeftArrow 22`, `UpArrow 32`, `RightArrow 28`, `DownArrow 6`, press |
| Space | `chr=' '` works. Flutter uses `Space (30)` (remote_page.dart:436-438) |
| Ctrl+C | `chr = 'c'` (lowercase, see the uppercase pitfall in §6), `modifiers = [Control]`, press |
| Win+R | `chr = 'r'`, `modifiers = [Meta]`, press |
| Win alone (Start) | `control_key = Meta (23)`, press |
| Shift+Tab, Ctrl+Shift+Esc | `control_key = Tab`, `modifiers=[Shift]` / `Escape`, `[Control, Shift]` |
| Alt+F4 | `control_key = F4`, `modifiers=[Alt]` |
| **Ctrl+Alt+Del** | `control_key = CtrlAltDel (100)`, `down = true`, `press = false` (keyboard.rs:487-499) |
| Lock screen | `control_key = LockScreen (101)`, `down = true` (keyboard.rs:473-479) |
| Held modifier (sticky accessory key) | either put it in `modifiers` of every following event (simplest), or send `control_key=Control, down=true` … `down=false`. With the latter, **every event in between must still list Control in `modifiers`**, otherwise fix_modifiers releases it |

**Ctrl+Alt+Del path:** in Legacy, `is_function_key` intercepts `CtrlAltDel` (input_service.rs:2132-2148) → `send_sas()` (2555-2565).

- On the physical console it sends `ipc::Data::SAS` to the **installed** RustDesk service (`POSTFIX_SERVICE`), which calls `SendSAS`.
- In an RDP session it calls `SendSAS` directly. That call temporarily sets the `SoftwareSASGeneration` policy (src/platform/windows.rs:943-...).
- UNVERIFIED: a portable/non-installed host has no service, so SAS likely fails.

`LockScreen` calls `platform::lock_screen()` (input_service.rs:1540-1577).

### 2.4 ControlKey values (proto:211-296)

```
Unknown 0  Alt 1  Backspace 2  CapsLock 3  Control 4  Delete 5  DownArrow 6  End 7  Escape 8
F1 9  F10 10  F11 11  F12 12  F2 13  F3 14  F4 15  F5 16  F6 17  F7 18  F8 19  F9 20
Home 21  LeftArrow 22  Meta 23 (Win)  Option 24 (deprecated)  PageDown 25  PageUp 26  Return 27
RightArrow 28  Shift 29  Space 30  Tab 31  UpArrow 32  Numpad0..9 33..42  Cancel 43  Clear 44
Menu 45 (deprecated→Alt)  Pause 46  Kana 47 … Convert 53  Select 54  Print 55  Execute 56
Snapshot 57 (PrtSc)  Insert 58  Help 59  Sleep 60  Separator 61  Scroll 62  NumLock 63  RWin 64
Apps 65  Multiply 66  Add 67  Subtract 68  Decimal 69  Divide 70  Equals 71  NumpadEnter 72
RShift 73  RControl 74  RAlt 75  VolumeMute 76  VolumeUp 77  VolumeDown 78  Power 79
CtrlAltDel 100  LockScreen 101
```

- Note the odd F-key order: F10, F11 and F12 are 10, 11 and 12, while F2 is 13.
- Host mapping: input_service.rs:2639-2715. VolumeMute/Up/Down and Power are **not** in KEY_MAP, so a Windows host ignores them in Legacy.

---

## 3. Touch messages

```proto
PointerDeviceEvent { oneof { TouchEvent touch_event = 1; } repeated ControlKey modifiers = 2; }   // proto:190
TouchEvent { oneof { TouchScaleUpdate scale_update=1; TouchPanStart pan_start=2;
                     TouchPanUpdate pan_update=3; TouchPanEnd pan_end=4; } }                     // proto:181
TouchScaleUpdate { int32 scale = 1; }   // delta*1000, 0 = end                                  // proto:157
```

- **Windows host:** only `scale_update` is implemented. `scale != 0` means Ctrl down plus `mouse_scroll_y(scale)` (Ctrl+wheel zoom), and `scale == 0` releases Ctrl (input_service.rs:1233-1252, 1518-1528). Pan start/update/end are ignored on desktop hosts and are only forwarded on Android/iOS hosts (connection.rs:3240-3267).
- **No real Windows touch injection (InjectTouchInput) exists.** For "direct touch" mode, use MouseEvent MOVE + LEFT DOWN/UP at the finger position, as Flutter touch mode does (§1.5).
- The gate is the same `peer_keyboard_enabled()` (connection.rs:3269).

---

## 4. Clipboard (text)

```proto
enum ClipboardFormat { Text=0; Rtf=1; Html=2; ImageRgba=21; ImagePng=22; ImageSvg=23; Special=31; }  // proto:338
message Clipboard { bool compress=1; bytes content=2; int32 width=3; int32 height=4;
                    ClipboardFormat format=5; string special_name=6; }                              // proto:348
message MultiClipboards { repeated Clipboard clipboards = 1; }                                        // proto:358
```

### 4.1 Encoding

- Text `content` is UTF-8.
- If `compress = true`, `content` is a **zstd frame**. The sender uses `zstd::bulk::Compressor` at the config level. The receiver uses `zstd::Decoder` with a 256 MiB cap (libs/hbb_common/src/compress.rs:1-55).
- The RustDesk sender compresses and sets `compress` only if the result is smaller (src/clipboard.rs:646-661).
- You may always send `compress=false` (clipboard.rs:748-757).

### 4.2 Host → client

- The host runs `clipboard_service`, which listens for OS clipboard changes and polls every 333 ms. It sends **only on change**: there is no initial push at connect, and nothing in the server calls `get_current_clipboard_msg` (src/server/clipboard_service.rs:53-110, src/clipboard.rs:15).
- On Windows it produces a `MultiClipboards` (Text/Html/Rtf/images…) (clipboard_service.rs:190-226, clipboard.rs:61-73).
- Per connection, `get_msg_if_not_support_multi_clip(lr.version, lr.my_platform)` downgrades it to a single `Clipboard` (the first Text entry) when the client's LoginRequest `version < 1.3.0` or `my_platform` is `""` or `"iOS"` (connection.rs:1132-1141, clipboard.rs:549-562, 788-806). Non-text-only changes are then dropped.
  - So an iOS client (`my_platform = "iOS"`; UNVERIFIED: string comes from the external `whoami` crate, client.rs:3841) receives **plain `Clipboard{format: Text}`**. Handle both message types anyway.
- Subscription requires `can_sub_clipboard_service()`: clipboard permission **and** keyboard permission **and** `one-way-clipboard-redirection != "Y"` (connection.rs:2353-2357).
- The official iOS client decompresses it and hands the text to Flutter, which calls `Clipboard.setData` (src/client/io_loop.rs:1858-1893, flutter/lib/models/model.dart:359).

### 4.3 Client → host

- Send `Message.clipboard = Clipboard{format: Text, content: utf8, compress: false|true}`, or `multi_clipboards`.
- The host accepts it when the connection is a Remote session (`should_handle_text_clipboard_message`, connection.rs:5835-5837) **and** `clipboard_enabled()` holds (permission && !client's disable_clipboard option, connection.rs:2348-2350). It does **not** need the keyboard permission.
- The host writes the OS clipboard and adds an owner marker (`dyn.com.rustdesk.owner`), so it does **not** echo the text back (connection.rs:3400-3427, clipboard.rs:283-296, 405-436, 612-627).
- When to send:
  - Desktop clients send on every local change and, if `sync_init_clipboard` is set, once after the first PeerInfo (client/io_loop.rs:1808-1814, 682-719).
  - The official **mobile** client sends no Clipboard messages. Its "paste" types the text as `seq` instead (flutter/lib/common/widgets/toolbar.dart:509-512).
  - For iOS: send on app foreground or when UIPasteboard changes (changeCount), and/or offer "type clipboard" via `seq`.

### 4.4 Options

- The client sends `LoginRequest.option.disable_clipboard = Yes` (OptionMessage field 8, proto:689) if view-only or the user disabled clipboard (src/client.rs:3433-3435). It can toggle later via `Misc.option` (client.rs:3241-3247; host handles it at connection.rs:5039-5046).
- Leave it NotSet to enable.

---

## 5. Host-side gating and defaults

| Gate | Where | Default |
|---|---|---|
| `enable-keyboard` (mouse + keyboard + touch + OsLogin) | connection.rs:594, gate `peer_keyboard_enabled` 2344 | **on**: `option2bool("enable-*")` = `value != "N"` (libs/hbb_common/src/config.rs:2924-2926) |
| `enable-clipboard` | connection.rs:595, 2348 | **on** |
| `access-mode` = `full` → all on, `view` → all off (flutter host builds) | connection.rs:2696-2711 | custom |
| Per-user ControlPermissions (from server/web console) override the local options | connection.rs:2713-2743 | n/a |
| `one-way-clipboard-redirection` = Y → no host→client clipboard | connection.rs:2353-2357, keys.rs:141 | off |
| Client `disable_keyboard` (OptionMessage 12, "view only") / `disable_clipboard` (8) | connection.rs:5039-5056 | NotSet |
| Live toggles in the host's connection-manager UI → `Misc.permission_info {Keyboard=0, Clipboard=2, …; enabled}` | connection.rs:803-830, 1401-1411 | n/a |
| At login, the host sends `PermissionInfo(enabled=false)` **only for disabled** permissions (absence means enabled) | connection.rs:678-700 | n/a |
| ViewCamera / FileTransfer / Terminal connections force keyboard off | connection.rs:2197-2230, 3198 | n/a |

---

## 6. Pitfalls

- **Key repeat.** The host never generates auto-repeat. The client must repeat itself (e.g. resend `press=true` for a held arrow or backspace). UNVERIFIED that Windows SendInput does not typematic-repeat: by design repeat comes from the keyboard driver.
- **Stuck-key safety net.** Keys recorded as down (Legacy control_key/chr, Map scancodes) are auto-released after 360 s (checked every 10 s), and all of them are force-released when the cursor service resets (input_service.rs:932-943, 1020-1033, 42-48). Always send matching ups. On disconnect, relative-mouse state is cleared (connection.rs:7086). UNVERIFIED: no explicit modifier release on disconnect on Windows besides the reset above.
- **Stuck or unexpectedly released modifiers.** Every Legacy key-down and every mouse DOWN releases host modifiers that are not in `modifiers` (fix_modifiers). Keep `modifiers` consistent with your sticky Ctrl/Alt/Win/Shift UI state in **every** key and mouse event, including mouse DOWN for Ctrl+click. AltGr exception: Ctrl is not released while Alt is down (input_service.rs:1044-1049).
- **Uppercase with Ctrl.** In the hotkey path (Ctrl/Alt/Win), `VkKeyScanExW('C')` reports Shift, so enigo also presses Shift, which turns the event into Ctrl+Shift+C. Send lowercase letters for shortcuts.
- **Characters outside the BMP** via `chr`/`seq` use surrogate downs without ups (win_impl.rs:257-266). Usually fine.
- **Unicode-injected text** (`KEYEVENTF_UNICODE` / VK_PACKET) is ignored by some apps such as games, some VMs and remote consoles. Use Map mode scancodes for those.
- **UAC / secure desktop / lock screen.**
  - Before every injection the host calls `try_change_desktop()`, which attaches the input thread to the current input desktop (src/platform/windows.rs:1034-1051; called at input_service.rs:1289, 1725, 2210, 2255). This works when RustDesk runs as the **installed service**.
  - A portable/unelevated host cannot input into UAC prompts or elevated windows. The host tells the client through `Misc.uac` (15), `Misc.foreground_window_elevated` (16) and `Misc.portable_service_running` (20) (connection.rs:5674-5719, proto:844-849). The client can ask for elevation via `Misc.elevation_request` (18).
  - For the lock or logon screen there is also `Message.os_login` (typing the password plus Return, only when the logon screen is detected) (connection.rs:3394-3399, 2486-2520).
- **Mobile platform string.** Identifying as `iOS` gets text-only `Clipboard` messages (good), and nothing in input handling depends on the client platform except `Pause` handling for Windows peers (keyboard.rs:1315-1347).
- **Clamp absolute moves to the display rect**, and use `x ≤ left+width` (not `-1`) for a Windows peer to allow edge snapping (input_model.dart:2399-2406).
- `Misc.block_input` / privacy mode can also block local input on the host. That is separate from remote input (connection.rs:1291-1318).
