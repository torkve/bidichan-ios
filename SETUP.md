# Build & deploy without a Mac

Everything builds on a GitHub Actions **macOS runner**; you never need a Mac or
Xcode locally. Two deliveries are wired up: **TestFlight** (internal) and
**ad-hoc OTA** (install from a link). One-time setup below, then it's push-button.

## 0. Prerequisites

- A paid **Apple Developer Program** membership (enrolled).
- This project pushed to a GitHub repo (e.g. `github.com/torkve/bidichan-ios`),
  with the `Vendor/bidichan-src` submodule intact.
- A **private** GitHub repo for fastlane match (e.g. `bidichan-match`) — stores
  the encrypted certs/profiles. Empty is fine.

## 1. Create the App Store Connect API key (Team key)

App Store Connect ▸ **Users and Access ▸ Integrations ▸ App Store Connect API**
▸ generate a key with the **App Manager** role (a *Team* key — individual keys
cannot manage provisioning). Download `AuthKey_XXXXXXXXXX.p8` (once!). Note the
**Key ID** and the **Issuer ID**.

Base64 the key for the secret:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

## 2. A token for the match repo

Create a GitHub Personal Access Token that can read **and write** the private
match repo (match *pushes* the new certs/profiles during bootstrap):

- **Fine-grained** (recommended): Repository access limited to the match repo,
  Permissions ▸ **Contents: Read and write** (Metadata: Read is auto-included).
  Nothing else. If the repo lives under an org, approve the token for that org.
- **Classic**: the **`repo`** scope.

> Normal builds run `match(readonly: true)` and only clone, so read alone would
> cover `build.yml`; write is only needed for the one-time `bootstrap` lane. The
> same secret serves both, so grant read+write.

Compute the basic-auth secret:

```sh
printf '%s' 'YOUR_GH_USERNAME:YOUR_PAT' | base64
```

## 3. Repository secrets

Add these to **bidichan-ios ▸ Settings ▸ Secrets and variables ▸ Actions**:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | your 10-char Team ID |
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | API Issuer ID |
| `ASC_KEY_P8_BASE64` | base64 of the `.p8` (step 1) |
| `MATCH_GIT_URL` | HTTPS URL of the private match repo |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 `user:pat` (step 2) |
| `MATCH_PASSWORD` | a passphrase you choose (encrypts the match repo) |
| `DEVICE_UDIDS` | your device UDID(s) for ad-hoc — see step 4 (skip if TestFlight only) |

## 4. Register your device (for ad-hoc)

This repo is public, so the device UDID must **not** be committed (a UDID is a
persistent device fingerprint). Instead put it in the **`DEVICE_UDIDS` secret**;
the bootstrap workflow writes `fastlane/devices.txt` from it at run time (that
path is git-ignored).

Find your iPhone's **UDID** (Finder with the device connected, or Settings ▸
General ▸ About ▸ tap the serial). Set `DEVICE_UDIDS` to one device per line,
`UDID Name` (the name is optional and may contain spaces):

```
00008120-0011223344556677 My iPhone
```

TestFlight does not need this; ad-hoc OTA does. Adding a device later means
updating the secret and re-running the bootstrap workflow so the ad-hoc profile
picks up the new UDID.

## 5. One-time Portal setup (web UI, no Mac needed)

An App ID carrying the Network Extension entitlement plus an App Group can't be
created headlessly with only an API key — the App Store Connect API has no
app-creation endpoint, and app groups aren't in it. So do this once in Apple's
web portals:

1. **Bundle IDs** — [Developer portal ▸ Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   ▸ **＋**. Create two App IDs and, on each, enable the **App Groups** and
   **Network Extensions** capabilities:
   - `torkve.bidichan` (name "bidichan")
   - `torkve.bidichan.tunnel` (name "bidichan tunnel")
2. **App Group** — Identifiers ▸ the top-left type dropdown ▸ **App Groups** ▸
   **＋** ▸ create `group.torkve.bidichan`. Then edit each bundle ID, click
   **Configure** next to App Groups, and assign this group to **both**.
3. **App Store Connect app record** (needed for TestFlight) —
   [App Store Connect ▸ Apps](https://appstoreconnect.apple.com/apps) ▸ **＋ ▸
   New App**, platform iOS, pick the `torkve.bidichan` bundle ID, set a name +
   SKU. Then in that app ▸ **TestFlight**, add yourself as an **internal tester**
   so builds show up in the TestFlight app.

## 6. One-time bootstrap (signing)

Run the **bootstrap-signing** workflow (Actions ▸ bootstrap-signing ▸ Run
workflow). Using the API key it registers your device(s) (from the
`DEVICE_UDIDS` secret) and creates the development / App Store / ad-hoc
certificates and provisioning profiles into the match repo.

It must finish **green**. If a `match` pass fails while *generating a profile*,
the step-5 Portal setup is incomplete — almost always the App Group isn't
assigned to both bundle IDs. Fix that and re-run.

## 7. Ship

| Trigger | Result |
|---|---|
| push to `main` | build ▸ **TestFlight** (internal) |
| push a tag `v*` | build ▸ **TestFlight** + **ad-hoc OTA** GitHub Release |
| Actions ▸ build ▸ Run workflow | pick `beta`, `adhoc`, or `both` |

**TestFlight:** open the TestFlight app on the iPhone, install the build
(internal testers skip Beta App Review; allow a few minutes for processing).

**Ad-hoc OTA:** open the GitHub Release created by the run and tap **Install
bidichan** on the registered iPhone. On first launch, trust the certificate in
Settings ▸ General ▸ VPN & Device Management. This path has no processing wait.

## How it fits together

```
GitHub Actions (macos-26)
  ├─ gomobile bind ./mobile ▸ Vendor/Bidichan.xcframework
  ├─ fastlane match (readonly)  ▸ certs + profiles
  ├─ xcodegen generate          ▸ bidichan.xcodeproj
  ├─ fastlane gym               ▸ signed .ipa
  └─ upload_to_testflight  and/or  GitHub Release + itms-services manifest
```

The Go core is rebuilt from the pinned `Vendor/bidichan-src` submodule each run;
bump it with `git -C Vendor/bidichan-src pull` + commit when bidichan changes.
