# RustDesk direct-IP protocol: transport, handshake, encryption, auth

Source: RustDesk tag `1.5.3` (shallow clone, HEAD 95cca3f, 2026-11-09), hbb_common at fae47e0.
Paths: `src/...` are in the RustDesk 1.5.3 source (github.com/rustdesk/rustdesk, tag `1.5.3`, commit 95cca3f), `hbb/...` are under `libs/hbb_common`,
`proto/message.proto` is `libs/base/protos/message.proto`, `proto/rendezvous.proto` is
`libs/hbb_common/protos/rendezvous.proto`.

## TL;DR

On stock RustDesk, a **direct-IP session is plaintext protobuf over TCP**. The host's direct listener
calls `create_tcp_connection(..., secure=false, ...)`, so it skips the SignedId/PublicKey key exchange
entirely. The stock client skips it too and does not warn about it. Auth is the salted SHA-256
challenge/response. A Swift client needs **SwiftProtobuf + SHA-256 (CryptoKit)** only. It needs no
libsodium for direct IP.

```
Client (iOS)                                   Host (Windows, direct-server=Y)
   | TCP connect host:21118 (no preamble) --------->|  accept, admit_unauthorized, max pkt 128 KiB
   |                                                |  identity_handshake(secure=false): no-op
   |<---------------- Message{hash: Hash{salt,challenge}}   (on_open)
   |<---------------- Message{misc: PermissionInfo...} (0..n, only for disabled perms)
   |<---------------- Message{test_delay}  (every ~1 s once the last one was answered)
   |-- Message{test_delay} (echo unchanged) ------->|
   |-- Message{login_request: LoginRequest} ------->|
   |       password = SHA256(SHA256(pw||salt)||challenge)
   |                                                |  [2FA on]  LoginResponse{error:"2FA Required"}
   |-- Message{auth_2fa{code}} -------------------->|
   |                                                |  [click mode] LoginResponse{error:"No Password Access"}
   |                                                |     ... user clicks Accept in CM ...
   |<---------------- Message{login_response{peer_info}}
   |<---------------- video_frame / cursor / audio / misc ...  (video subscribed immediately)
   |<---------> test_delay echo forever; >30 s silence on either side = close
```

---

## 1. Direct IP access

| Item | Value | Cite |
|---|---|---|
| Host enable option | `direct-server` = `"Y"` (off unless exactly "Y") | hbb/src/config.rs:2968, 2924-2935; src/rendezvous_mediator.rs:1407-1410 |
| Port option | `direct-access-port` (int). If it is unset or <=0, the port is `RENDEZVOUS_PORT+2` = **21118** | src/rendezvous_mediator.rs:1393-1401; hbb/src/config.rs:119 |
| Bind | Dual-stack `[::]:port` (IPV6_V6ONLY off), IPv4 fallback | hbb/src/tcp.rs:271-300 |
| Listener lifetime | Spawned unconditionally at service start. It polls the option every 1 s and stops when the option is off or `stop-service`=Y | src/rendezvous_mediator.rs:329-332, 1403-1467 |
| Client default port | `check_port(peer, RELAY_PORT+1)` = 21118 when the typed id has no port | src/client.rs:440-452 |
| Typed-id forms accepted as "direct" | IPv4 with optional `:port`, IPv6 or `[v6]:port`, `host.tld:port` | hbb/src/lib.rs:387-425; src/common.rs:3079-3081 |

- Transport: raw TCP with TCP_NODELAY, using the **same `BytesCodec` framing** as every other TCP
  path (`Stream::from(stream, local_addr)` → `FramedStream::from` → `Framed::new(.., BytesCodec::new())`)
  (src/rendezvous_mediator.rs:1444-1458; hbb/src/tcp.rs:169-176).
- **No preamble.** Nothing rendezvous-related is involved. The host passes the accepted socket straight
  to `create_tcp_connection` (src/rendezvous_mediator.rs:1452-1459). PunchHole/RequestRelay are only
  used on the rendezvous and relay paths (src/server.rs:425-438).
- `secure=false` is passed (src/rendezvous_mediator.rs:1456). `identity_handshake` therefore does
  nothing: its whole body sits under `if secure && ...` (src/server.rs:264-266). The host **sends no
  SignedId and expects no PublicKey**. The first frame the client receives is `Hash`.
- Client side: on an IP or domain:port it returns immediately, with `pk=None`, from
  `_start` (src/client.rs:440-467). It never calls `secure_connection` and sends nothing before the
  host's Hash. `confirm_insecure_connection` is suppressed for direct IP
  (src/client/io_loop.rs:240-243).
- Admission before auth: at most 64 unauthenticated connections in total and 16 per IP
  (src/server/connection.rs:92,97,127-130, src/server.rs:222-224). The pre-auth max frame payload is
  **128 KiB** (src/server/connection.rs:105; src/server.rs:226). The limit is lifted at authorization
  (src/server/connection.rs:1899).
- Gates in `on_open`: the IP `whitelist` option (src/server/connection.rs:1423-1446,1508), and
  `allow-only-conn-window-open` (1511-1516).

## 2. Framing (`BytesCodec`)

Each frame is a little-endian variable-length header of 1 to 4 bytes, followed by the payload.
- The low 2 bits of the first byte give `header_len - 1` (0..3). The whole header, read as a
  little-endian uint of `header_len` bytes, is `(payload_len << 2) | (header_len - 1)`.
- Encoder (hbb/src/bytes_codec.rs:123-145):
  - len <= 0x3F: 1 byte `len<<2`
  - len <= 0x3FFF: u16 LE `(len<<2)|1`
  - len <= 0x3FFFFF: 3 bytes LE `(len<<2)|2`
  - len <= 0x3FFFFFFF (`MAX_FRAME_LENGTH`): u32 LE `(len<<2)|3`
  - anything larger is an error.
- Decoder: `head_len = (b0 & 3) + 1`, then assemble LE, `n >>= 2`, then check against
  `max_packet_length` (hbb/src/bytes_codec.rs:46-76). Use the minimal encoding. The decoder accepts any
  header width.
- Payload = protobuf `Message` bytes. When a key is set, the payload is the encrypted blob instead
  (hbb/src/tcp.rs:193-198).
- Worked examples:
  - 5-byte payload → `14` + payload.
  - 0-byte payload (empty `Message`) → `00`.
  - 300 bytes → `0x4B1` → `B1 04` + payload.
  - 100 000 bytes → `0x61A82` → `82 1A 06` + payload.
  - 0x3F bytes → 1-byte header `FC`. 0x40 bytes → `01 01`. Tests at hbb/src/bytes_codec.rs:150-200 confirm the sizes.

## 3. Key exchange and encryption

**Direct IP: none (see §1). Plaintext is the normal stock behaviour.** The scheme below is used on
rendezvous, punch and relay paths. It is documented here for completeness, and for any future host
that might secure direct IP.

1. Host → client: `Message{signed_id: SignedId{id}}` (src/server.rs:266-310).
   - `id` = **`crypto_sign` combined form** (64-byte Ed25519 signature followed by the message). It is
     signed with the host's **permanent Ed25519 key** (`Config::get_key_pair`).
   - The signed message is the protobuf `IdPk{id=host_id, pk=<fresh ephemeral X25519 box pk, 32B>,
     dtls_fingerprint="", kx_version=1}` (proto/rendezvous.proto:4-13).
2. The client verifies with `crypto_sign_open` against the host's Ed25519 pk. It gets that pk from the
   **rendezvous server's signed `PunchHoleResponse/RelayResponse` blob**, verified with the rendezvous
   key `rs_pk` (src/client.rs:1661-1689; src/common.rs:2419-2440). It then checks `IdPk.id == peer_id`.
   - If the client has no trusted pk, it sends an empty `Message` and stays plaintext (src/client.rs:1690-1700).
   - On a signature mismatch it sends `PublicKey{}` (empty), and the host sets `key_confirmed=false`
     (src/client.rs:1757-1766; src/server.rs:341-343).
   - There is **no TOFU and no pinning**. Without rendezvous the client cannot verify the host at all.
3. Client → host: `Message{public_key: PublicKey{asymmetric_value=client ephemeral X25519 pk (32B),
   symmetric_value=crypto_box_easy(key32, nonce=24×0x00, host_box_pk, client_box_sk) (48B),
   kx_version=min(advertised,1)}}`.
   - `key32` = `crypto_secretbox_keygen` (src/common.rs:2449-2456; src/client.rs:1723-1739).
   - The host opens it with `crypto_box_open_easy`, zero nonce (hbb/src/tcp.rs:404-424).
   - The host rejects `kx_version > advertised` (src/server.rs:325-331).
4. Stream key (hbb/src/stream.rs:87-104):
   - `kx_version=0`: the same `key32` is used in both directions.
   - `kx_version=1`: split keys. `subkey(dir) = crypto_generichash(outlen=32, key=key32, msg="rdkx-spl" || u8 dir || u32le advertised
     || u32le picked || initiator_pk(32) || responder_pk(32))`, where dir 1 = initiator and 2 = responder.
     The initiator is the client (the sender of the sealed key). It sends with subkey(1) and receives
     with subkey(2) (hbb/src/tcp.rs:44-46, 346-380).
5. Per frame: `crypto_secretbox_easy` (16-byte MAC, then the ciphertext, so +16 bytes).
   - Nonce = 24 bytes: **bytes 0..7 = u64 LE counter, rest zero**. There are separate send and
     receive counters, both starting at 0 and **pre-incremented**, so the first message uses counter 1
     (hbb/src/tcp.rs:248-252, 382-402).
   - Frames with payload length <= 1 are passed through undecrypted and do not advance the counter
     (hbb/src/tcp.rs:383-385).
   - Test vector, v0: key=32×0x11, first message "hello" → `3b768f827fdcc4af555b9e42533be6611e2c333481`
     (hbb/src/tcp.rs:463-469). The split-key vectors are at 470-496.
- libsodium functions for a secured (non-direct) path: `crypto_sign_open` (Ed25519 combined),
  `crypto_box_keypair`, `crypto_box_easy` (X25519-XSalsa20-Poly1305), `crypto_secretbox_keygen`,
  `crypto_secretbox_easy` / `crypto_secretbox_open_easy`, and `crypto_generichash` (BLAKE2b, keyed)
  for v1. **Direct IP needs none of them.** CryptoKit has no XSalsa20, so the secured path would need
  swift-sodium or TweetNaCl.

## 4. Login

Host → client `Hash{salt (1), challenge (2)}` (proto/message.proto:333-336; src/server/connection.rs:545-550, 1519-1521):
- `salt` = `Config::get_effective_permanent_password_salt()`. It can be `""` if the stored password
  storage is unusable (hbb/src/config.rs:1556-1572).
- `challenge` = 6 random chars, regenerated per connection (hbb/src/config.rs:1211-1224).

**Password hash** (client src/client.rs:4757-4762, 4889-4900; host src/server/connection.rs:2521-2541):
```
h1 = SHA256( utf8(password) || utf8(salt) )        // 32 raw bytes, not hex
h2 = SHA256( h1 || utf8(challenge) )
LoginRequest.password = h2 (32 raw bytes)          // empty = request click-to-accept
```
The same salt is used for the temporary (one-time) password and the permanent password
(src/server/connection.rs:2621-2635). The comparison is constant-time.

`LoginRequest` (proto/message.proto:68-89; filled by the client at src/client.rs:3779-3895):

| # | field | what to send |
|---|---|---|
| 1 | username | **The string the user typed, e.g. `192.168.1.10` or `10.0.0.5:21118`.** The host requires `is_direct_ip_access(username)` or `username == host ID`, otherwise it returns error `"Offline"` (src/server/connection.rs:2993-2999) |
| 2 | password | h2 or empty |
| 4 | my_id | any non-empty id string. It is matched against the host's `id-whitelist` if one is set (1448-1476) |
| 5 | my_name | display name |
| 6 | option | `OptionMessage`. Include `supported_decoding` (abilities). Without it the host forces VP9 only (src/server/connection.rs:2745-2755) |
| 7/8/15/16 | union | unset = remote desktop. Others: file_transfer, port_forward, view_camera, terminal |
| 9 | video_ack_required | false (otherwise you must ack frames) (2858, 1079-1083) |
| 10 | session_id | random u64. It keys the "recent session" re-login within 30 s (2675-2700) |
| 11 | version | e.g. `"1.5.3"`. Gates features (§5) |
| 12 | os_login | only for terminal |
| 13 | my_platform | e.g. `"iOS"` (any string) |
| 14 | hwid | empty |
| 17 | avatar | empty |
| 18/19 | trusted_device_v2_token / _supported | empty / false |

Host decision (src/server/connection.rs:2907-3131):
- `approve-mode` option values: `"password"` → Password, `"click"` → Click, anything else → Both
  (hbb/src/password_security.rs:77-86).
- `verification-method` values: `use-temporary-password`, `use-permanent-password`, or (default)
  both (hbb/src/password_security.rs:42-75).
- Click mode, or Both with no valid password: the host opens the Connection Manager prompt and, for
  client version >= 1.2.0, sends `LoginResponse{error:"No Password Access"}`. It **keeps the
  connection open** until the user clicks Accept, then sends PeerInfo
  (3047-3060, 734-740). With an empty password in Both mode, the CM prompt is shown (3066-3074).
- Wrong password → `"Wrong Password"`, connection stays open, retry allowed (3076-3085).
  - Throttle: more than 6 failures/minute → `"Please try 1 minute later"`. More than 30 in total →
    `"Too many wrong attempts"` (4565-4580).
  - The temporary password rotates after 10 consecutive failures (2568-2619).
- Success → `Message{login_response: LoginResponse{peer_info: PeerInfo}}` (1852-2236).
  - PeerInfo carries `username, hostname, platform, displays[], current_display, version,
    features, encoding (SupportedEncoding), resolutions, platform_additions(JSON),
    windows_sessions` (proto/message.proto:125-140).
  - A capture failure gives `LoginResponse{error: <display err>}` instead (2154-2157).
  - The temporary password rotates on every successful login (1908-1911).
- Error strings: "Empty Password", "Wrong Password", "Wrong 2FA Code", "2FA Required", "No Password
  Access", "Offline" (src/client.rs:117-122). Others are free text, e.g. "Your ID is blocked by the
  peer" or "Connection not allowed".
- Changing the login type (remote vs file etc.) within one connection → "Connection not allowed"
  (2830-2850).
- **2FA:** if the host has TOTP 2FA enabled (`auth_2fa::get_2fa`), a correct password produces
  `LoginResponse{error:"2FA Required"}` (1856-1887). The client then sends
  `Message{auth_2fa: Auth2FA{code:"123456", hwid:empty, trust_this_device:false}}`
  (proto/message.proto:95-99; handled at 3104-3131). The 2FA step cannot be skipped, but a re-login
  within 30 s of the same session can bypass it (`is_recent_session(true)`).
- **Trusted devices** only matter when 2FA is on, the permanent password was used, and the option
  `enable-trusted-devices` is set. They are **skipped** when `trusted_device_v2_supported=false &&
  hwid empty` (src/server/connection/trusted_devices.rs:10-21). Direct IP is explicitly allowed in
  plaintext (line 12). A Swift client can ignore trusted devices.
- Hard deadline: an unauthorized connection is closed after **180 s** (src/server/connection.rs:89, 181-186, 745-748).

## 5. Version / compatibility

- `get_version_number("a.b.c")` = `a*1e6 + b*1e3 + c*10` (hbb/src/lib.rs:264-280).
  `LoginRequest.version` gates the following:
  - \>= 1.2.0: the host sends "No Password Access" in click mode (src/server/connection.rs:3054).
  - \>= 1.2.4: Windows multi-session `windows_sessions` and wait-for-`SelectedSid`
    (2309, 4036-4061), and multi-UI-session display switching (src/common.rs:65,143-150;
    src/server/connection.rs:4677-4681). Below 1.2.4 the host also pushes extra legacy
    display/keyboard messages (4628-4634, 5074-5080).
  - File copy/paste, remote print, and overwrite detection are also version-gated (2009-2015, 3459, 3759, 6941).
- **No minimum client version is enforced** anywhere in the login path (verified by grep of
  `get_version_number` in connection.rs). Recommendation: send `"1.2.4"` or later, so that the host
  takes the modern code paths, but declare only the features you implement.
  - Caveat: with version >= 1.2.4 on an installed Windows host with "share RDP" enabled (`platform::is_share_rdp()`, src/platform/windows.rs:1061; a native setting, not a config option) and more than one
    session, PeerInfo carries `windows_sessions` and **video does not start until you send
    `Misc{selected_sid}`** (2213-2234, 4036-4061).
- `kx_version` (KX v1 split keys) and trusted-device v2 are new in this codebase, dated 2026-10/11.
  Absent fields = 0 = the original scheme. Irrelevant for direct IP.
- Old host 1.2.3 — **UNVERIFIED** (no 1.2.3 source in this shallow clone). From the compat code here,
  the following should hold:
  - The framing and the `Hash`/`LoginRequest`/`LoginResponse` field numbers are unchanged (they are
    proto3 additive).
  - The h1/h2 hash is identical. An old host stores the permanent password as plaintext and salts it
    with `Config::get_salt()`. That is transparent to the client.
  - There is no KX v1, no trusted devices, and no 180 s login grace or unauthorized cap.
  - Direct IP on 1.2.3 is believed to also pass `secure=false` (plaintext). **UNVERIFIED.**
  - The host's video codec choice depends on its own build (VP8/VP9/AV1 software; H264/H265 only
    with hwcodec).

## 6. Keepalive / timeouts

- Every 1 s, if no TestDelay is outstanding, the host sends `TestDelay{last_delay, target_bitrate}`.
  The client must **echo it unchanged** (`from_client=false`) (src/server/connection.rs:1187-1210;
  src/client.rs:4268-4274). This runs before login as well. The round trip feeds the video QoS.
  Client-initiated TestDelay (`from_client=true`) is echoed by the host (3132-3136).
- The host closes with "Timeout" if it **receives nothing for 30 s** (1188-1191). Any parsed frame
  resets the timer (1033). The echo is the keepalive.
- The stock client also gives up after 30 s with no data (src/client/io_loop.rs:337).
- Send timeout on the host: 12 s for remote/video, 120 s for file/terminal/port-forward
  (src/server/connection.rs:508-509, 2983-2992).
- `auto-disconnect-timeout` option: the host disconnects after N minutes of inactivity, if that is
  configured (1176-1182, 5732).
- Graceful close: `Message{misc: Misc{close_reason:"..."}}` (2889-2896).

## 7. Other things a reimplementer must get right

- Tolerate host messages arriving before Hash/LoginResponse completes. `Misc` permission messages
  (keyboard, clipboard, audio, file... disabled) are sent right after `on_open`
  (src/server/connection.rs:671-702), and TestDelay is also sent early. Ignore unknown `Message`
  union cases.
- Do not send any message before Hash. If you do, it must be a valid `Message`. An unparseable frame
  is silently dropped (1035). Do not exceed 128 KiB before auth.
- Do not send `PublicKey` on direct IP. The host has no handler and drops it silently, but this is
  not a supported path.
- After `LoginResponse{peer_info}` the host **subscribes video for the primary display immediately**
  (`try_sub_monitor_services`, 2231-2234). No client request is needed, except for the
  `windows_sessions` caveat in §5.
  - Video arrives as `Message{video_frame}`. The codec is chosen from `OptionMessage.supported_decoding`
    across all connected clients, defaulting to VP9 when absent (2745-2755; libs/scrap/src/common/codec.rs ~181-200).
    Implement at least a VP9 decoder (not native on iOS), or advertise H264/H265 if the host has
    hwcodec. **UNVERIFIED**: whether a Windows 1.5.3 host build without hwcodec can emit H264. Check
    the video spec.
- Keyboard and clipboard availability is reported via permission messages and `OptionMessage`
  (`disable_keyboard` etc.).
- Windows: the host runs as a service, and the direct listener lives in the service process
  (src/rendezvous_mediator.rs:325-332). Whether the installer opens TCP 21118 in Windows Firewall is
  **UNVERIFIED**. Over a VPN you may need a firewall rule.
- Security note: with direct IP the password challenge/response is replay-safe (per-connection
  challenge), but `h1` is an offline-crackable function of the password and the public salt, and the
  whole session (keystrokes, clipboard, screen) is cleartext. Rely on the VPN for confidentiality.

## One-time passwords and login errors (RustDesk 1.5.3)

Verified in `src/server/connection.rs` and live against a macOS host.

- **Same hash.** A one-time ("temporary") password is checked exactly like a
  permanent one: `SHA256(SHA256(pw + salt) + challenge)` with the same `Hash`
  salt. The host tries the one-time password first, then the permanent one.
- **Which ones count** is the host option `verification-method`:
  `use-both-passwords` (default), `use-temporary-password`, or
  `use-permanent-password`. A one-time password sent to a permanent-only host
  is just `Wrong Password`.
- **Rotation.** The host makes a new one-time password as soon as one has let
  a peer in (`update_temporary_password()` after authorization), not when the
  peer leaves. After 10 consecutive wrong tries it rotates too. A client must
  never store it.
- **Length.** 6 characters by default (`temporary-password-length` 8 or 10).
- **Login errors** arrive as `LoginResponse.error` strings (`src/client.rs`):
  `Wrong Password`, `Empty Password`, `No Password Access` (the host only
  accepts connections approved by click), `2FA Required`, `Wrong 2FA Code`,
  `Offline`. After `Wrong Password` the host keeps the connection open and
  also offers the person at that computer an accept dialog. Oxide closes it
  and asks again instead.
- **Testing:** the local host's options and current one-time password can be
  read and set over its IPC socket (`/tmp/RustDesk-<uid>/ipc`, framed JSON
  `{"t":"Config","c":["temporary-password",null]}` or `{"t":"Options",...}`).
  Editing `RustDesk2.toml` directly doesn't stick: the running app writes its
  own copy back.
