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
