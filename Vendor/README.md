# Vendor/

## Bidichan.xcframework

The gomobile-built iOS binding of bidichan's `mobile` package. It is **not**
committed — CI builds it on the macOS runner and drops it here before
`xcodegen generate` / `xcodebuild`:

```sh
# from Vendor/bidichan-src (the bidichan repo, added as a git submodule)
gomobile bind -target=ios -o ../Bidichan.xcframework -ldflags="-s -w" ./mobile
```

The framework exposes the `Mobile*` Objective-C classes (`MobileClient`,
`MobileConfig`, `MobilePacketFlow`, `MobileShellSession`). Only the
`BidichanTunnel` extension links it; the app talks to the extension over the
NETunnelProvider IPC and never imports it directly.

## bidichan-src (git submodule)

Add once:

```sh
git submodule add git@github.com:torkve/bidichan.git Vendor/bidichan-src
```
