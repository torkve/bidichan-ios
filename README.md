# bidichan-ios

A native iOS client for [bidichan](https://github.com/torkve/bidichan) — a
point-to-point encrypted tunnel disguised as HTTPS/WebSocket. The app hosts the
bidichan connect-side peer inside a **Packet Tunnel Provider** (a system tunnel,
mirroring the desktop's TUN device) and drives all channel kinds: TUN,
SOCKS5/HTTP proxy, TCP port-forward, and an interactive shell.

## Architecture

```
 bidichan.app (SwiftUI)  ──NETunnelProvider IPC──▶  BidichanTunnel.appex
   profiles / connect                                 hosts Bidichan.xcframework
   channel UI / terminal                              (gomobile bidichan core)
                                                       NEPacketTunnelFlow ⇄ Go tun
                                                              │ TLS(uTLS iOS)+WS+yamux
                                                              ▼   unmodified bidichan server
```

The Go networking core is reused verbatim via `gomobile bind` (preserving the
exact wire protocol and a Safari-on-iPhone uTLS fingerprint). See
`Vendor/README.md`. The app never links the Go framework — only the extension
does; the app sends control requests over `sendProviderMessage`.

## Staying connected

A phone changes networks constantly, so the tunnel is built to outlive the one
it started on. When the connection drops — Wi-Fi to cellular, a lift, a dead
spot — the app does **not** fall back to "Disconnected":

- The Go core resumes the same session over a fresh connection, replaying from
  byte counters both ends exchange, so open channels and the TCP connections
  running through them continue where they left off. The tun channel is the
  exception: packets are dropped while the link is away, and the connections
  inside the tunnel retransmit as they would on any real link.
- The extension reports `reasserting` for the duration, which the app shows as
  "Reconnecting…" with the channel list still in place.
- An `NWPathMonitor` in the extension tells the core the moment iOS switches
  interfaces, so the dead socket is replaced immediately instead of after a
  timeout.
- **Reconnect window** (per profile, default 90 s) is how long the network may
  be gone before the session is given up. Past it the extension rebuilds the
  session and replays the tun channel and every channel the app had opened, so
  the tunnel comes back on its own — only the connections inside it are lost.

The server must be running a bidichan that supports resumption; against an
older one the app still reconnects, it just cannot preserve the connections
inside the tunnel.

## Sharing a profile

A profile can be handed to another device — this app or the Android one — as a
link. The format lives in the Go core both clients embed, so either can read
what the other wrote.

The payload rides in the link's *fragment*, which is never sent in a request:
if the link is opened in a browser instead of the app, the settings do not
leave the device. It is not encryption, though. Including the pre-shared key is
a separate choice on the share screen, and a link that carries one is a
credential — send it the way you would send the key, and delete it afterwards.

Three ways across, because the obvious one does not always work:

- **As a code.** The share screen renders the link as a scannable code, which
  is the shortest path when both devices are to hand. A profile carrying a
  certificate can be too large to encode; the screen says so when it is.
- **As text, tapped.** Both apps register the `bidichan://profile` scheme, so a
  link opens the app directly wherever it is tappable.
- **As text, pasted.** Most chat apps — Telegram among them — only linkify web
  addresses, and never an app's own scheme, so a link sent that way arrives as
  plain text that cannot be tapped. Copy it and use **Import from a link** in
  the `+` menu. Nothing is saved until the incoming profile has been shown in
  full.

## Targets

- `BidichanKit` — shared framework: profile model, Keychain, App Group paths,
  the app↔extension message protocol, and `NETunnelProviderManager` orchestration.
- `bidichan` — the SwiftUI app.
- `BidichanTunnel` — the Packet Tunnel Provider extension (hosts the Go core).

## Building without a Mac

The Xcode project is generated from `project.yml` (XcodeGen) and built on a
GitHub Actions macOS runner; see `.github/workflows/` (added in the CI phase).
Nothing here requires editing in Xcode. Signing is manual, resolved on CI via
fastlane match; `Config/Signing.xcconfig` is written from secrets.

Local project generation (on a Mac/CI):

```sh
brew install xcodegen
xcodegen generate
```

## Requirements

- iOS 26 or later.
- A paid Apple Developer Program membership (the Packet Tunnel Provider
  entitlement is not available to free accounts).
- App Group `group.torkve.bidichan` and bundle IDs
  `torkve.bidichan` (+ `.tunnel`, `.kit`).
