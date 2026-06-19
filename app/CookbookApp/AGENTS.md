# CookbookApp — the buildable iOS + macOS targets

## Purpose

The thin app shell that turns `CookbookKit` into shippable iOS and macOS apps. Holds the XcodeGen project, the two targets, the per-platform Info.plists, and the app entry point.

## Ownership

- `project.yml` — XcodeGen spec defining two targets: `Cookbook` (iOS, `SDKROOT iphoneos`) and `CookbookMac` (macOS, `SDKROOT macosx`, sandbox off, ad-hoc signing). They share `Sources/`.
- `Sources/CookbookApp.swift` — `@main`. Boots demo (seeded, no network) or live mode; parses launch args (`-live`, `-uiTab`, `-uiRecipe`); seeds base URL + token from `SettingsDefaults`.
- `Info-iOS.plist` / `Info-macOS.plist` — separate per-target plists.
- `Cookbook.xcodeproj` — generated; do not hand-edit, regenerate via XcodeGen.

## Local Contracts

- **Each target MUST have its OWN Info.plist.** The two targets sharing one `info.path` was the root cause of the iOS letterbox bug: the macOS target clobbered the shared plist and dropped `UILaunchScreen`, so iOS ran non-fullscreen/cramped. Keep `Info-iOS.plist` (with `UILaunchScreen`, `UIRequiresFullScreen=false`, `UIApplicationSceneManifest`, `NSAppTransportSecurity.NSAllowsLocalNetworking=true`) and `Info-macOS.plist` distinct. When a layout looks broken, check the plist/window before debugging SwiftUI views.
- **Default base URL is `http://127.0.0.1:8000`, not `localhost`.** `localhost` resolves to `::1` first; if the server is single-stack that hangs POSTs. (Server side: bind `--host ::`.)
- **Regenerate after target/plist edits.** Run XcodeGen; never hand-edit `.xcodeproj`.
- `-askDemo` is a temporary debug launch trigger (fires a hardcoded query); it's test scaffolding and must not ship.

## Work Guidance

- Regenerate: `xcodegen generate` in this folder.
- Build/run on iPhone 17 sim (UDID `758A450D-4858-4440-BD21-D196D73E7F86`).

## Verification

- A correct iOS build is full-screen (no letterbox). Live mode must reach the server (dual-stack bind + `127.0.0.1`).

## Child DOX Index

None.
