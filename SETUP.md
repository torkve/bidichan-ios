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

Create a GitHub Personal Access Token (classic, `repo` scope, or a fine-grained
token limited to the match repo). Compute:

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

Optional (only if `app_groups` needs an Apple-ID fallback — see step 5):
`FASTLANE_APPLE_ID`, `FASTLANE_APP_SPECIFIC_PASSWORD`.

## 4. Register your device (for ad-hoc)

Find your iPhone's **UDID** (Finder with the device connected, or Settings ▸
General ▸ About ▸ tap the serial). Add it to `fastlane/devices.txt`:

```
Device ID	Device Name
00008120-0011223344556677	My iPhone
```

Commit and push. (TestFlight does not need this; ad-hoc does.)

## 5. One-time bootstrap

Run the **bootstrap-signing** workflow (Actions ▸ bootstrap-signing ▸ Run
workflow). It:

- registers the bundle IDs `torkve.bidichan` and `torkve.bidichan.tunnel` with
  the **App Groups** and **Network Extensions** capabilities,
- creates the App Store Connect app record,
- registers the device(s) from `devices.txt`,
- creates the development / App Store / ad-hoc certificates and provisioning
  profiles into the match repo.

**App Group:** capability enabling is automated, but creating and associating
the specific group `group.torkve.bidichan` sometimes needs an Apple-ID session.
If signing later complains about the app group, either tick **"Also create the
App Group"** when dispatching bootstrap (set `FASTLANE_APPLE_ID` +
`FASTLANE_APP_SPECIFIC_PASSWORD` first), or create it once in the Developer
portal (Identifiers ▸ App Groups ▸ `group.torkve.bidichan`) and assign it to
both bundle IDs, then re-run bootstrap so the profiles pick it up.

Add yourself as an **internal tester** in App Store Connect ▸ your app ▸
TestFlight, so builds appear in the TestFlight app.

## 6. Ship

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
