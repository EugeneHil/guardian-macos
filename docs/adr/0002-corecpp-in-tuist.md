# ADR-0002: warden-core built by CMake and linked as a static library

- Status: accepted
- Date: 2026-10-22

## Context

The policy engine lives in the C++17 library `warden-core` (separate repository). The macOS agent must call it from Swift through an Objective-C++ bridge (`CoreBridge`). Design §10 left open how the library enters the Tuist project: a prebuilt xcframework, or a CMake build driven from Xcode.

## Decision

- `warden-core` is a git submodule at `external/warden-core`, pinned to the release tag `v0.1.0`.
- `scripts/build-corecpp.sh` configures it with its own `macos` CMake preset (Release, arm64, tests off) into `build/corecpp` and builds `warden_core`. It runs as a pre-build script of the small `WardenCoreLib` target, which `CoreBridge` depends on. The script lives in a separate target because an unsandboxed script phase next to `CoreBridge`'s "Copy Headers" phase makes Xcode emit a warning, and warnings are errors for us.
- `CoreBridge` is a `.staticFramework`: its objects link straight into the extension and the test bundles, so nothing extra is embedded or signed. This keeps the inside-out ad-hoc signing of ADR-0001 unchanged.
- Consumers (`DlpExtension` and every test bundle that uses CoreBridge: `DlpExtensionTests`, `WardenAppTests`, `CoreBridgeTests`) add `libwarden_core.a -lc++` to `OTHER_LDFLAGS`, because a static framework does not carry the archive.
- The build is arm64-only, matching the VM and the single supported host architecture.

## Why not an xcframework

An xcframework needs a separate packaging step, a stored binary or a release pipeline in `warden-core`, and a way to keep it in sync with the tag. Building from source in the pre-build script keeps one source of truth (the submodule tag), is reproducible, and costs a few seconds on a cold build only; CMake is incremental afterwards.

## Bumping warden-core

1. `git -C external/warden-core fetch --tags && git -C external/warden-core checkout vX.Y.Z`
2. Update the expected version in `coreVersionIsPinned` (`CoreBridgeTests.swift`) and rerun `scripts/test.sh`.
3. Commit the changed submodule pointer together with the test change.

## Dependencies

No new dependency is introduced: `warden-core` is our own code, and CMake/Ninja are build tools already used by the sibling repository. `nlohmann/json` is private to the static library and is fetched by its CMake build; it is not visible to this project.

## Consequences

- Building requires `cmake` and `ninja` on `PATH` (Homebrew); CI must install them and check out submodules.
- The first build needs network access for the CMake `FetchContent` of `nlohmann/json`.
