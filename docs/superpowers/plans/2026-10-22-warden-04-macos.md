# Warden macOS Agent Implementation Plan (Plan 4 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Warden macOS agent in `warden-macos`: a SwiftUI menu bar app (WardenApp), an Endpoint Security system extension (DlpExtension), an Objective-C++ bridge (CoreBridge) over warden-core, a Tuist project, CI, the design-system components, the e2e checklist and README, released as `v0.1.0` after the spec §9 scenario passes in the VM.

**Architecture:** The app polls the server (SPKI-pinned HTTPS, `ETag`) and pushes the policy to the extension over XPC; it drains events from the extension and uploads them. The extension keeps an on-disk policy cache, answers `AUTH_OPEN` synchronously on a fast path, hands candidate paths to a watchdog-guarded evaluator, and fails open on every error. All testable logic lives in Swift files with no `EndpointSecurity` import; the ES client sits behind a thin adapter verified in the VM.

**Tech Stack:** Swift 6 (language mode 6, strict concurrency `complete`), SwiftUI + `@Observable`, Objective-C++17, Tuist 4.212.0 (mise), XCTest/Swift Testing, EndpointSecurity, SystemExtensions, `Synchronization.Mutex`, CryptoKit (system), Security, UserNotifications, `warden-core` submodule at `v0.1.0` built by CMake into a static library. **No third-party dependencies.**

**Spec:** `docs/superpowers/specs/2026-10-20-warden-design.md` (§3 constraints, §4.1 components, §4.3 extension, §4.4 UI, §4.6 design system, §7 quality, §9 acceptance). Prior art: `docs/adr/0001-adhoc-signed-es-extension.md` (read it first), `docs/vm-setup.md`, the throwaway spike on branch `spike/WRD-3-adhoc-sysext` (`Spike/Project.swift`, `Spike/sign.sh`, `Spike/Ext/Info.plist`), Plan 2 (core API), and the contract `warden-server/docs/api.md`.

**Where the work happens:** all tasks run in `/Users/eugene/Mine/git/warden/warden-macos` (Claude Code started there so the guard hook is active). Paths are relative to that repo. Work lands in five PRs to `develop`: A = Tasks 1–3, B = Tasks 4–8, C = Tasks 9–13 (ES adapter, app services, VM smoke gate), D = Tasks 14–17, E = Tasks 18–19 (Task 19 is the release). Branches: A `feature/WRD-18-macos-scaffold`, B `feature/WRD-19-extension-logic`, C `feature/WRD-20-es-adapter-and-services`, D `feature/WRD-21-app-ui`, E `chore/WRD-22-docs-release`. **Ask the owner (AskUserQuestion) before every merge, before applying rulesets, before anything that touches the VM-based e2e run or the VPS, and before pushing the tag.** Squash merges only; `gh pr update-branch <n>` when behind. Commit trailer and PR footer as in `HANDOFF.md`. Claude cannot drive the VM: steps marked **[owner, VM]** are run by the owner, who pastes the outputs. The agent token, admin password and SSH keys never go into chat, files, logs or commits.

## Global Constraints

- Swift only through Swift Concurrency: `async/await`, actors, `AsyncStream`, `Task`. No GCD (`DispatchQueue`), `OperationQueue`, Combine or completion handlers in our code; callback APIs (XPC, `OSSystemExtensionRequest`, `URLSession` delegate, `UNUserNotificationCenter`) are wrapped once at the boundary. **Only exception:** the synchronous ES handler block; it never `await`s, reads the policy through a `Mutex`, answers the fast path inline, and starts a `Task` plus a watchdog `Task` for candidates. No force unwraps, no `try!`, no `fatalError` outside unreachable-by-construction code.
- Warnings are errors: Swift 6 mode, `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, `GCC_TREAT_WARNINGS_AS_ERRORS=YES`, ObjC++ `-Wall -Wextra -Wpedantic`. SwiftLint `--strict` and SwiftFormat `--lint` are gates. Coverage gate: Swift logic (ViewModels, services, extension logic) ≥ 80 % lines.
- No new dependency without an ADR. This plan adds none (system frameworks only; warden-core is the submodule, tag `v0.1.0`, linked as a prebuilt static library).
- Ad-hoc signing per ADR-0001: build with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`, then `codesign --force --sign - --entitlements <file>` extension first, app second; `ENABLE_HARDENED_RUNTIME=NO`, `CODE_SIGN_STYLE=Manual`, deployment target macOS 15.0; the extension bundle is named after its bundle identifier (`PRODUCT_NAME` = identifier); extension `Info.plist` has `CFBundlePackageType=SYSX`, `NSSystemExtensionUsageDescription`, `NSEndpointSecurityEarlyBoot=false`, `NSEndpointSecurityMachServiceName`; extension entitlements `com.apple.developer.endpoint-security.client` + `com.apple.security.application-groups`; app entitlement `com.apple.developer.system-extension.install` (+ the same app group).
- Identifiers: app `io.github.eugenehil.warden`, extension `io.github.eugenehil.warden.ext`, app group `io.github.eugenehil.warden`, Mach service `io.github.eugenehil.warden.ext` (must be prefixed by the app group, as in the spike). Logger subsystem `io.github.eugenehil.warden`; file paths are logged `privacy: .private`.
- Extension policy cache `/Library/Application Support/Warden/policy.json`, mode 0600, written atomically. Event ring buffer 1000 entries, dedup of identical (process path, file, decision) within 5 s. Policy poll every 10 s. XPC peer check pins the bundle identifier only (no Team ID, spec §3).
- Server contract is `warden-server/docs/api.md`: Bearer `wdn_<64 hex>`, SPKI pin = `base64(SHA-256(DER SubjectPublicKeyInfo))` (never fall back to CA validation), `If-None-Match` with the last `ETag`, events in batches ≤ 500 (at-least-once; retry on 5xx/timeout, drop on `400 invalid_events`, wait `Retry-After` on 429, stop on 401), compare `Content-Type` by media type only, cache the last good policy and keep enforcing it when the server is unreachable.
- Fail-open everywhere in the extension: no policy yet, unreadable or invalid cache, invalid pushed policy, evaluator error, missed watchdog, `std::bad_alloc` → allow.
- TDD: failing test first, watch it fail, then implement. Never commit to `main`/`develop`; Conventional Commits; never `--no-verify`. Repository text in English. No `.env*`, `*.pem`, `*.key`, `*.p12`, `*.cer`, `config.local.json` anywhere (tests generate keys at run time).

## Review Focus

1. Fail-open under bad state: before the cache loads, with a truncated/garbage `policy.json`, with an invalid pushed policy (old policy stays active), and with a throwing/slow evaluator the extension allows and never traps. *(Tasks 4–6: `AllowsUntilPolicyLoaded`, `CorruptCacheAllowsAndKeepsRunning`, `InvalidPushedPolicyKeepsPrevious`)*
2. Deadlines: a slow responsible-process lookup or evaluation yields exactly one `allow` at 50 % of the remaining time, and a late deny afterwards is discarded, never a second response. *(Task 6: `WatchdogAllowsOnce`, `LateVerdictIsDiscarded`)*
3. Path forms: file names with invalid UTF-8, `..`/trailing slash/`//`, > PATH_MAX lengths, `/tmp/x` vs `/private/tmp/x` in process matchers, unsigned processes (empty signing/team ids) must not crash or mis-match. *(Task 2 bridge tests, Task 3, Task 6)*
4. Hostile or broken server: wrong pin refuses without CA fallback; 200 with invalid JSON, a body over 1 MiB, `version` ≠ `ETag`, a wrong media type, 401/429/5xx keep the last good policy and follow the checklist rules; the token never appears in logs or errors. *(Tasks 10–12)*
5. Restarts and floods: extension killed (`kill -9`) → app reconnects and re-pushes when versions differ; app restarted → policy re-fetched; 10 000 events overflow drop the oldest, upload stays ≤ 500 per batch with a bounded pending buffer. *(Tasks 5, 11–13)*

Known and documented limitations: ES path form for process paths unverified (bridge normalizes); allow events for candidate paths are recorded too (deduplicated); no read-only mode (ADR-0001 finding 5: denies cover writes); fail-open window after a crash unmeasured; extension cannot run on a SIP-enabled Mac without the paid entitlement.

---

## File structure

```
Project.swift, Tuist.swift, mise.toml, .swiftlint.yml, .swiftformat, .gitmodules
external/warden-core                      submodule @ v0.1.0
scripts/{build-corecpp,build,sign,test,lint,coverage}.sh, coverage_gate.py, test_coverage_gate.py, tokens.py
CoreBridge/Sources/WD*.{h,mm}             Objective-C++ bridge (only place Swift meets C++)
Shared/                                   compiled into app, extension and both test targets
  BundleIDs.swift  ProcessIdentity.swift  AccessEvent.swift  WardenXPC.swift
DlpExtension/Sources/Logic/               no EndpointSecurity import; compiled into DlpExtensionTests
  PolicyHolder  PolicyStore  PolicyController  EventQueue  OpenCoordinator  ExtensionService
DlpExtension/Sources/ES/                  EndpointSecurityClient, SecurityProcessResolver, main.swift (VM-verified)
DlpExtension/{Info.plist,DlpExtension.entitlements}, DlpExtension/Tests/
WardenApp/Sources/{Models,Services,ViewModels,Views,DesignSystem,Entry}   Entry/ and Views/ excluded from tests
WardenApp/{WardenApp.entitlements}, WardenApp/Tests/
docs/{e2e-checklist.md, adr/0002-corecpp-in-tuist.md}
```

Test targets: `CoreBridgeTests`, `DlpExtensionTests` (compiles `Shared/**` + `DlpExtension/Sources/Logic/**`), `WardenAppTests` (compiles `Shared/**` + `WardenApp/Sources/**` minus `Entry/**` and `Views/**`). Test targets have no host app.

---

### Task 1: Tuist skeleton, signing, lint, CI

**Files:**
- Create: `mise.toml`, `Tuist.swift`, `Project.swift`, `.swiftlint.yml`, `.swiftformat`, `scripts/{build,sign,test,lint}.sh`, `.github/workflows/ci.yml`
- Create: `Shared/BundleIDs.swift`, `DlpExtension/Info.plist`, `DlpExtension/DlpExtension.entitlements`, `WardenApp/WardenApp.entitlements`, stub `WardenApp/Sources/Entry/WardenApp.swift` (`@main`, empty `MenuBarExtra`), stub `DlpExtension/Sources/ES/main.swift`, `DlpExtension/Tests/BundleIDsTests.swift`
- Modify: `README.md` (build/test/lint commands), `CLAUDE.md` (add a "Build & test" section; the file is project-owned, edit by hand if the guard hook blocks it)

**Interfaces:**
- Produces: `enum BundleIDs { static let app, extension, appGroup, machService: String }` with the values from Global Constraints (`extension` is spelled `` `extension` `` or `ext`; use `ext`). Targets `WardenApp` (app), `DlpExtension` (systemExtension, `PRODUCT_NAME = io.github.eugenehil.warden.ext`), `DlpExtensionTests`, `WardenAppTests`; shared `adhoc` settings dictionary as in the spike plus the warning flags from Global Constraints and `SWIFT_VERSION = 6.0`.
- `scripts/build.sh` = `tuist generate --no-open`, unsigned `xcodebuild` into `build/`, then `scripts/sign.sh` (ADR-0001 finding 1; prints `codesign -dvv` identifier lines). `scripts/test.sh [--coverage]` runs `xcodebuild test` for both test schemes with `CODE_SIGNING_ALLOWED=NO`. `scripts/lint.sh` runs `swiftlint --strict` and `swiftformat --lint .`.
- CI `.github/workflows/ci.yml` on `macos-latest` (jobs named `macos-build`, `macos-quality`; `tokens` is added in Task 14): `actions/checkout` with `submodules: recursive`, `jdx/mise-action` for Tuist, `brew install cmake ninja swiftlint swiftformat`; `macos-build` = `scripts/build.sh`; `macos-quality` = `scripts/lint.sh` + `scripts/test.sh --coverage` + coverage gate (Task 3).

- [ ] **Step 1: Branch** `git switch develop && git pull --ff-only && git switch -c feature/WRD-18-macos-scaffold`.
- [ ] **Step 2: Write the failing test** `DlpExtension/Tests/BundleIDsTests.swift`: `bundleIDsAreConsistent()` asserts `BundleIDs.ext == BundleIDs.app + ".ext"`, `BundleIDs.machService.hasPrefix(BundleIDs.appGroup)`, and that the extension `Info.plist` file (located via `#filePath`, two levels up) has `NSEndpointSecurityMachServiceName == BundleIDs.machService` and `CFBundlePackageType == "SYSX"` (parse with `PropertyListSerialization`).
- [ ] **Step 3: Run to verify it fails** — `scripts/test.sh` → Expected: FAIL (`BundleIDs` undefined / no project). Create the Tuist skeleton only far enough for the failure to be the missing symbol.
- [ ] **Step 4: Implement** `BundleIDs`, `Project.swift` (copy the spike's structure; `.unitTests` targets without host: `DlpExtensionTests` sources `Shared/**`, `DlpExtension/Sources/Logic/**`, `DlpExtension/Tests/**`; `WardenAppTests` analogous), the extension `Info.plist` (spike's plus `NSEndpointSecurityMachServiceName = $(BundleIDs machService literal)`), entitlements per Global Constraints, SwiftLint config (opt-in `force_unwrapping`, `force_try`, `fatal_error_message`; custom error-severity rules rejecting `DispatchQueue`, `OperationQueue` and `import Combine` everywhere), `.swiftformat` (Swift 6 target, 4 spaces, line width 120).
- [ ] **Step 5: Run to verify it passes** — `scripts/test.sh` → Expected: `** TEST SUCCEEDED **` for both schemes; `scripts/build.sh` ends with `built: build/.../WardenApp.app` and `codesign -dvv` shows `Identifier=io.github.eugenehil.warden.ext`, `Signature=adhoc`, the endpoint-security entitlement; `scripts/lint.sh` exits 0.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "build: add Tuist skeleton, ad-hoc signing scripts, lint and CI"`.

### Task 2: warden-core submodule and CoreBridge

**Files:**
- Create: `external/warden-core` (submodule at tag `v0.1.0`), `scripts/build-corecpp.sh`, `CoreBridge/Sources/{WDProcessInfo,WDAccessRequest,WDDecision,WDPolicy,WDEngine}.{h,mm}`, `CoreBridge/Sources/CoreBridge.h` (umbrella), `CoreBridge/Tests/CoreBridgeTests.swift`, `docs/adr/0002-corecpp-in-tuist.md`
- Modify: `Project.swift` (targets `CoreBridge`, `CoreBridgeTests`; `DlpExtension` and the two test targets depend on `CoreBridge`)

**Interfaces:**
- Produces (Objective-C, all `NS_SWIFT_SENDABLE`, immutable after init):
  - `WDProcessInfo(path:signingId:teamId:)` — empty string means absent.
  - `WDAccessRequest(filePath:process:responsible:)`, `responsible` nullable.
  - `WDDecision`: `BOOL deny`, `NSString *ruleId` (empty on allow).
  - `WDPolicy`: `+policyWithJSON:error:` `NS_SWIFT_NAME(init(json:))` (`NSData`, fails with `NSError` domain `WDPolicyErrorDomain` whose `userInfo[WDPolicyValidationErrorsKey]` is `[String]` of `warden::describe` lines); `int64_t version`; `NSUInteger ruleCount`.
  - `WDEngine`: `-initWithPolicy:`; `-evaluate:` → `WDDecision`; `-isPotentiallyProtectedPath:(const char *)path length:(NSUInteger)length` → `BOOL` (allocation-free, no `NSString`); `+coreVersion` → `"0.1.0"`.
- `evaluate` normalizes `process.path` and `responsible.path` with `warden::normalizePath` before building the C++ request (ADR-0001: ES path form unverified) and catches every C++ exception (`std::bad_alloc` included) returning an allow `WDDecision`.
- `scripts/build-corecpp.sh` runs `cmake --preset macos -S external/warden-core -B build/corecpp -DWARDEN_BUILD_TESTS=OFF` (Release), builds `warden_core`, and leaves `build/corecpp/libwarden_core.a`; Tuist runs it as a pre-build script of `CoreBridge` (`.pre(script:)`), `HEADER_SEARCH_PATHS = external/warden-core/include` (+ nlohmann is private to the static lib, no include needed), `OTHER_LDFLAGS = build/corecpp/libwarden_core.a`, `CLANG_CXX_LANGUAGE_STANDARD = c++17`, product `.staticFramework` so it links into the extension without embedding.

- [ ] **Step 1: Submodule** — `git submodule add https://github.com/EugeneHil/warden-core.git external/warden-core && git -C external/warden-core checkout v0.1.0`.
- [ ] **Step 2: Write the failing tests** `CoreBridgeTests.swift`, with a helper `policy(_ json: String)`: `parsesAndEvaluatesDeny` (rule `**/.env` + `{signingIdPrefix: "com.google.Chrome"}`; request for `/Users/a/p/.env` by `com.google.Chrome.helper` → `deny`, `ruleId` equals the rule id); `allowsNonBlocklistedProcess`; `invalidPolicyThrowsWithPaths` (error `userInfo` contains a line starting `rules[0]`); `normalizesProcessPath` (matcher `{path: "/private/tmp/x"}`, process path `/tmp/x` → deny); `responsibleProcessIsMatched` (opener unsigned, responsible `com.anthropic.claude` → deny); `prefilterTakesRawBytes` (bytes of `/Users/a/.env` → true, `/usr/lib/libc.dylib` → false, embedded invalid UTF-8 bytes → no crash); `coreVersionIsPinned` (`"0.1.0"`).
- [ ] **Step 3: Run to verify it fails** — `scripts/test.sh` → Expected: FAIL (no `CoreBridge` module).
- [ ] **Step 4: Implement** the bridge and the Tuist wiring. `.mm` files own all C++ types; headers expose only Foundation types.
- [ ] **Step 5: Run to verify it passes** — `scripts/test.sh` → Expected: all `CoreBridgeTests` pass; build log shows no warnings.
- [ ] **Step 6: Write `docs/adr/0002-corecpp-in-tuist.md`** (≤ 40 lines): CMake pre-build static library vs xcframework (spec §10 left it to the builder), `.staticFramework` choice so the extension needs no embedded framework (simplifies ad-hoc signing), arm64-only, how to bump the submodule tag, why no new dependency.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: add CoreBridge over warden-core v0.1.0"`.

### Task 3: Shared models, XPC contract, coverage gate

**Files:**
- Create: `Shared/ProcessIdentity.swift`, `Shared/AccessEvent.swift`, `Shared/WardenXPC.swift`, `scripts/coverage.sh`, `scripts/coverage_gate.py`, `scripts/test_coverage_gate.py`, `DlpExtension/Tests/SharedModelsTests.swift`
- Modify: `.github/workflows/ci.yml` (coverage step), `README.md`

**Interfaces:**
- Produces (all `Sendable`, `Codable`, `Equatable` unless noted):
  - `struct ProcessIdentity { var path: String; var signingId: String; var teamId: String }` — empty string = absent; `static let unknown`.
  - `enum AccessDecision: String { case allow, deny }`.
  - `struct AccessEvent: Identifiable { let id: UUID; var timestamp: Date; var process: ProcessIdentity; var responsible: ProcessIdentity?; var file: String; var decision: AccessDecision; var ruleId: String? }` with `static func uploadPayload(_ events: [AccessEvent]) throws -> Data` producing the server batch format (`ts` as `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC; empty `signingId`/`teamId` omitted; `responsible` null when nil; `ruleId` omitted when nil/empty; strings truncated to 4096 UTF-8 bytes on a character boundary).
  - `@objc protocol WardenExtensionXPC` (NSXPC, async): `apply(policyData: Data) async throws -> Int64` (returns the applied version), `currentPolicyVersion() async -> Int64` (0 = none), `drainEvents(max: Int) async -> Data` (JSON array of `AccessEvent`), `subscribe(client: WardenClientXPC) async`.
  - `@objc protocol WardenClientXPC`: `eventRecorded(_ eventData: Data) async` (one JSON `AccessEvent`).
  - `enum XPCCoding { static func encode(_ e: AccessEvent) throws -> Data; static func decode(_ d: Data) throws -> AccessEvent; static func decodeList(_ d: Data) throws -> [AccessEvent] }` (ISO-8601 dates).
- `scripts/coverage_gate.py --min 80 --exclude <regex>… <xccov.json>` reads `xcrun xccov view --report --json` output and exits 1 below the threshold; default excludes: `/Views/`, `/Entry/`, `/DesignSystem/`, `/ES/`, `Keychain`, `/Tests/`. `scripts/coverage.sh` runs `scripts/test.sh --coverage` and pipes both test bundles through the gate.

- [ ] **Step 1: Write the failing tests** — `SharedModelsTests.swift`: `eventRoundTripsThroughXPCCoding`; `uploadPayloadMatchesServerContract` (decode the payload and assert keys `ts`, `process.path`, `responsible == NSNull`, `decision`, absence of empty `teamId`, `ts == "2026-10-21T08:30:00Z"` for a fixed date); `uploadPayloadTruncatesLongStringsOnCharacterBoundary` (5000-byte emoji string → ≤ 4096 bytes, valid UTF-8). `scripts/test_coverage_gate.py` (`python3 -I -B -m unittest discover -s scripts`): `test_passes_at_threshold`, `test_fails_below_threshold`, `test_excluded_files_are_ignored`, `test_empty_report_fails`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` and the unittest command → Expected: FAIL (symbols / script missing).
- [ ] **Step 3: Implement** the models, XPC protocols, gate script and `coverage.sh`; add `python3 -I -B -m unittest discover -s scripts` and the coverage step to `macos-quality`.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh`, `python3 -I -B -m unittest discover -s scripts` → Expected: all pass; `scripts/coverage.sh` prints a total ≥ 80 % (the gate has little to cover yet; it must not fail on an almost-empty report).
- [ ] **Step 5: Commit, push, open PR A** — `git add -A && git commit -m "feat: add shared event models, XPC contract and coverage gate"`; `git push -u origin HEAD`; `gh pr create --base develop --title "feat: macOS scaffold, CoreBridge and shared models" --body …` (summary, test evidence; footer from HANDOFF). **Ask the owner before merging.** After merge: `gh api` apply the new required checks — **ask the owner**, then run `<warden-core>/tooling/github/bootstrap-repo.sh warden-macos "<description>" macos-build macos-quality` from inside this repo (idempotent; `tokens` is added after Task 14). If checks cannot be required before they have run once, merge first, then apply.

### Task 4: Extension policy state — `PolicyHolder`, `PolicyStore`, `PolicyController`

**Files:**
- Create: `DlpExtension/Sources/Logic/{PolicyHolder,PolicyStore,PolicyController}.swift`, `DlpExtension/Tests/{PolicyHolderTests,PolicyStoreTests,PolicyControllerTests}.swift`
- Modify: `Project.swift` only if the Logic glob needs adjusting

**Interfaces:**
- Consumes: `WDEngine`, `WDPolicy` (Task 2).
- Produces:
  - `final class PolicyHolder: Sendable` — `Mutex<WDEngine?>`; `func set(_ engine: WDEngine?)`, `func engine() -> WDEngine?`, `var version: Int64`; `func fastPathAllows(_ path: UnsafeRawBufferPointer) -> Bool` = no engine **or** `!engine.isPotentiallyProtectedPath(...)`; allocation-free.
  - `actor PolicyStore` — `init(fileURL: URL)`; `func load() throws -> Data?` (nil when absent); `func save(_ data: Data) throws` (write temp file in the same directory with mode 0600, `rename(2)`/`FileManager.replaceItemAt`, creates the directory); error enum `PolicyStoreError { unreadable(String) }`.
  - `protocol CacheClearing: Sendable { func clearCache() }` (implemented by the ES adapter, Task 9).
  - `actor PolicyController` — `init(holder: PolicyHolder, store: PolicyStore, cache: any CacheClearing, log: @Sendable (String) -> Void)`; `func start() async` (loads the cache; any failure → holder stays empty, logs, never throws); `func apply(_ data: Data) async throws -> Int64` (parse via `WDPolicy(json:)`; invalid → throws `PolicyApplyError.invalid([String])` and keeps the previous engine; valid → `store.save`, `holder.set`, `cache.clearCache()`, returns version; a failing `save` still applies in memory and logs); `func currentVersion() -> Int64`.

- [ ] **Step 1: Write the failing tests** — Holder: `AllowsUntilPolicyLoaded` (no engine → `fastPathAllows` true for `/Users/a/.env`), `ProtectedPathIsNotFastPath` (policy with `**/.env`), `UnrelatedPathIsFastPath`. Store: `SaveThenLoadRoundTrips`, `SavedFileIsMode0600` (`attributesOfItem` `.posixPermissions == 0o600`), `SaveIsAtomicNoPartialFileOnFailure` (read-only directory → throws, previous content intact), `LoadMissingReturnsNil`. Controller (fakes for cache/store dir in a temp dir): `StartLoadsCachedPolicy`, `CorruptCacheAllowsAndKeepsRunning` (garbage bytes in the file → holder empty, no throw), `ApplyPersistsAndClearsCache` (clear count == 1, file content equals data, version returned), `InvalidPushedPolicyKeepsPrevious` (throws, old version still current, no cache clear), `ApplyStillActivatesWhenSaveFails`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL (types missing).
- [ ] **Step 3: Implement** the three types as specified.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add extension policy holder, on-disk cache and controller"`.

### Task 5: `EventQueue`

**Files:**
- Create: `DlpExtension/Sources/Logic/EventQueue.swift`, `DlpExtension/Tests/EventQueueTests.swift`

**Interfaces:**
- Consumes: `AccessEvent` (Task 3).
- Produces: `protocol EventRecording: Sendable { func record(_ event: AccessEvent) async }`; `actor EventQueue: EventRecording` — `init(capacity: Int = 1000, dedupeWindow: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock())`; `func record(_:)` (drops a duplicate of the same `(process.path, file, decision)` within the window, drops the oldest on overflow, yields to `updates`); `func drain(max: Int) -> [AccessEvent]` (removes and returns up to `max`, oldest first); `nonisolated let updates: AsyncStream<AccessEvent>` (single consumer, `bufferingNewest(100)`); `var count: Int`. `ManualClock` test helper in `DlpExtension/Tests/Support/ManualClock.swift` (also copied to `WardenApp/Tests/Support/`).

- [ ] **Step 1: Write the failing tests** — `DrainReturnsOldestFirstAndRemoves`, `DrainRespectsMax`, `DuplicateWithinWindowIsDropped`, `DuplicateAfterWindowIsKept` (advance `ManualClock` 6 s), `DifferentDecisionIsNotDuplicate`, `OverflowDropsOldest` (capacity 3, record 5 → ids 3–5 remain), `TenThousandEventsStayBounded` (default capacity, `count == 1000`), `UpdatesStreamYieldsRecordedEvents`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** `EventQueue` with an array ring and a dictionary of last-seen instants keyed by a hashable tuple struct; prune the dictionary when it exceeds capacity.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add bounded deduplicating event queue"`.

### Task 6: `OpenCoordinator` — fast path, evaluation, watchdog

**Files:**
- Create: `DlpExtension/Sources/Logic/OpenCoordinator.swift`, `DlpExtension/Tests/OpenCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PolicyHolder` (Task 4), `EventRecording` (Task 5), `WDEngine`, `ProcessIdentity`.
- Produces:
  - `struct ProcessToken: Sendable, Hashable { let pid: Int32; let pidVersion: Int32 }` (from the audit token, built by the ES adapter).
  - `protocol ProcessResolving: Sendable { func identity(of token: ProcessToken) async -> ProcessIdentity? }`.
  - `struct OpenRequest: Sendable { let file: String; let process: ProcessIdentity; let responsible: ProcessToken?; let remaining: Duration }` — `remaining` = ES `deadline` minus now, computed by the adapter.
  - `enum OpenResponse: Sendable, Equatable { case allow, deny }`.
  - `final class ResponseGate: Sendable` — `init(_ respond: @escaping @Sendable (OpenResponse) -> Void)`; `func send(_ response: OpenResponse)` sends only the first call (`Mutex<Bool>`); the only place that calls `respond`.
  - `final class OpenCoordinator: Sendable` — `init(holder: PolicyHolder, resolver: any ProcessResolving, events: any EventRecording, clock: any Clock<Duration> = ContinuousClock(), log: @Sendable (String) -> Void)`; `func fastPathAllows(_ path: UnsafeRawBufferPointer) -> Bool` (delegates to holder); `func handleCandidate(_ request: OpenRequest, respond: @escaping @Sendable (OpenResponse) -> Void)` — non-async, starts the evaluation `Task` and the watchdog `Task` (`clock.sleep(for: request.remaining / 2)` then `gate.send(.allow)`); evaluation resolves the responsible process (if any; unresolvable → `nil`), calls `engine.evaluate`, records an `AccessEvent` (deny or allow, `ruleId` set on deny) and sends the verdict through the gate. Any thrown/absent engine → allow.
  - Text decoding helper `static func decodePath(_ bytes: UnsafeRawBufferPointer) -> String` — `String(decoding:as:UTF8.self)` (lossy for invalid UTF-8).

- [ ] **Step 1: Write the failing tests** (fake resolver with a controllable delay, recording `EventQueue`, `ManualClock`): `FastPathAllowsUnprotected`; `DeniedCandidateRecordsEventAndDenies`; `AllowedCandidateRecordsAllowEvent`; `ResponsibleProcessIsResolvedAndMatched` (opener unsigned, responsible resolves to a blocklisted signing id → deny); `UnresolvableResponsibleDoesNotCrash`; `WatchdogAllowsOnce` (resolver never returns, advance clock past 50 % of `remaining` → exactly one `allow`); `LateVerdictIsDiscarded` (resolver completes after the watchdog fired with a deny → respond count stays 1, response `allow`); `ResponseGateSendsOnlyOnce` (concurrent 100 sends → 1 call); `NoEngineAllows`; `InvalidUtf8PathDoesNotCrash` (`decodePath` of `[0x2F, 0xFF, 0x2E, 0x65, 0x6E, 0x76]` contains U+FFFD and evaluation completes); `VeryLongPathIsHandled` (4096-byte path).
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** `ResponseGate` and `OpenCoordinator`; keep every `await` out of the fast path; the two tasks race through the gate, no cancellation logic is required beyond cancelling the watchdog after a verdict.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS (run the suite 5 times: `for i in 1 2 3 4 5; do scripts/test.sh || break; done` — no flakes).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add open coordinator with fast path and watchdog"`.

### Task 7: `ExtensionService` — XPC server

**Files:**
- Create: `DlpExtension/Sources/Logic/ExtensionService.swift`, `DlpExtension/Tests/ExtensionServiceTests.swift`

**Interfaces:**
- Consumes: `PolicyController`, `EventQueue`, `WardenExtensionXPC`, `WardenClientXPC`, `XPCCoding`.
- Produces: `final class ExtensionService: NSObject, WardenExtensionXPC, NSXPCListenerDelegate` — `init(policy: PolicyController, events: EventQueue)`; implements the protocol (`apply` maps `PolicyApplyError` to an `NSError` with domain `io.github.eugenehil.warden` and the validation lines in `userInfo`), `subscribe` stores the client and starts one forwarding `Task` over `events.updates` (a client that throws is dropped); `static func peerRequirement() -> String` = `identifier "io.github.eugenehil.warden"`; `listener(_:shouldAcceptNewConnection:)` sets `exportedInterface`/`remoteObjectInterface` (`NSXPCInterface(with:)`), calls `setCodeSigningRequirement(Self.peerRequirement())`, exports `self`, resumes.

- [ ] **Step 1: Write the failing tests** (direct calls, no real XPC): `ApplyReturnsVersion`, `ApplyInvalidThrowsWithValidationLines`, `CurrentPolicyVersionIsZeroBeforeApply`, `DrainReturnsEncodedEventsAndEmpties`, `SubscribedClientReceivesRecordedEvent`, `PeerRequirementPinsBundleIdentifier` (string equals `identifier "io.github.eugenehil.warden"`).
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** as specified. `shouldAcceptNewConnection` is boundary glue: keep it a few lines and put every decision into the tested members.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add extension XPC service with identifier peer check"`.

### Task 8: PR B gate

**Files:** none new.

- [ ] **Step 1:** `scripts/lint.sh && scripts/coverage.sh` → Expected: exit 0; the extension logic files each ≥ 80 % in the xccov report (print the per-file table in the PR description).
- [ ] **Step 2:** Run the requesting-code-review pass on the branch diff (superpowers:requesting-code-review), fix findings in separate `fix:` commits.
- [ ] **Step 3: Push and open PR B** (`feat: extension policy state, event queue, open coordinator, XPC service`). **Ask the owner before merging.**

### Task 9: Endpoint Security adapter and the extension entry point

**Files:**
- Create: `DlpExtension/Sources/ES/EndpointSecurityClient.swift`, `DlpExtension/Sources/ES/SecurityProcessResolver.swift`, `DlpExtension/Sources/Logic/ESDeadline.swift`, `DlpExtension/Tests/ESDeadlineTests.swift`
- Modify: `DlpExtension/Sources/ES/main.swift`, `Project.swift` (link `EndpointSecurity` via `-lEndpointSecurity`, as in the spike)

**Interfaces:**
- Consumes: `OpenCoordinator`, `PolicyController`, `CacheClearing`, `ExtensionService`, `ProcessResolving`.
- Produces:
  - `Logic/ESDeadline.swift`: `enum ESDeadline { static func remaining(deadline: UInt64, now: UInt64, timebase: (numer: UInt32, denom: UInt32)) -> Duration }` (mach-absolute-time delta → `Duration`, clamped at zero, overflow-safe) — the only ES-adjacent code with unit tests.
  - `final class EndpointSecurityClient: CacheClearing` — if the `es_client_t` pointer forces `@unchecked Sendable`, confine it to this file with a one-line justification. `init(coordinator: OpenCoordinator, log:) throws`; creates the client with `es_new_client`, mutes the own process (`es_mute_process` with the own audit token), subscribes to `ES_EVENT_TYPE_AUTH_OPEN`; handler: build the raw path buffer from `es_string_token_t` (no `String`), `coordinator.fastPathAllows` → `es_respond_flags_result(client, message, UInt32.max, true)`; otherwise `es_retain_message`, build `OpenRequest` (process identity from `es_process_t`: path, `signing_id`, `team_id`; responsible token from `responsible_audit_token`), call `handleCandidate` with a respond closure that maps `.allow` → `es_respond_flags_result(…, UInt32.max, false)`, `.deny` → `(…, 0, false)`, then `es_release_message`; `func clearCache()` → `es_clear_cache`. Any unexpected state → allow.
  - `struct SecurityProcessResolver: ProcessResolving` — pid via `proc_pidpath`, signing id and team id via `SecCodeCopyGuestWithAttributes(kSecGuestAttributePid)` + `SecCodeCopySigningInformation`; returns nil on any failure.
  - `main.swift`: create `PolicyHolder`, `PolicyStore(fileURL: /Library/Application Support/Warden/policy.json)`, `EventQueue`, `PolicyController`, `OpenCoordinator`, `EndpointSecurityClient`; start `policy.start()` in a `Task` (events allowed until loaded); start the `NSXPCListener(machServiceName: BundleIDs.machService)` with `ExtensionService` as delegate; park with `try await Task.sleep` forever inside an async `@main`-free top-level (top-level `await` in `main.swift`). Logger subsystem as in Global Constraints.

- [ ] **Step 1: Write the failing tests** — `ESDeadlineTests`: `ConvertsMachTicksWithTimebase` (timebase 125/3, delta 3_000 ticks → 125_000 ns), `PastDeadlineClampsToZero`, `HugeDeadlineDoesNotOverflow` (`UInt64.max` delta).
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** `ESDeadline`, then the ES files (compile-checked by `scripts/build.sh`, behavior checked in the VM).
- [ ] **Step 4: Run tests + build** — `scripts/test.sh && scripts/build.sh` → Expected: PASS; signed bundle with Identifier `io.github.eugenehil.warden.ext`.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add Endpoint Security adapter and extension entry point"`. The VM smoke gate for this task runs in Task 13 Step 6, once the app can install the extension.

### Task 10: Settings, secrets, SPKI pin

**Files:**
- Create: `WardenApp/Sources/Services/{AgentSettings,SecretStore,KeychainSecretStore,SPKIPin}.swift`, `WardenApp/Tests/{AgentSettingsTests,SPKIPinTests}.swift`, `WardenApp/Tests/Support/InMemorySecretStore.swift`

**Interfaces:**
- Produces:
  - `struct AgentSettings: Equatable, Sendable { var serverURL: URL?; var spkiPin: String }` with `static func validate(urlText:String, pin:String, token:String) -> [SettingsIssue]` (`enum SettingsIssue: Equatable { invalidURL, notHTTPS, invalidPin, invalidToken }`: URL must be `https` with a host; pin is base64 of exactly 32 bytes; token matches `^wdn_[0-9a-f]{64}$`).
  - `protocol SettingsStoring: Sendable { func load() -> AgentSettings; func save(_ s: AgentSettings) }` and `UserDefaultsSettingsStore` (suite `io.github.eugenehil.warden`).
  - `protocol SecretStoring: Sendable { func token() async throws -> String?; func saveToken(_ t: String) async throws; func deleteToken() async throws }`; `KeychainSecretStore` (generic password, service `io.github.eugenehil.warden.agent-token`; Keychain calls are synchronous C APIs and are called directly); `InMemorySecretStore` in tests.
  - `enum SPKIPin { static let p256Header: [UInt8] /* 26-byte ASN.1 SPKI prefix for secp256r1 */; static func hash(x963PublicKey: Data) -> String?` (nil unless 65 bytes starting `0x04`); `static func hash(of certificate: SecCertificate) -> String?` (requires `kSecAttrKeyTypeECSECPrimeRandom`, 256 bits); `static func matches(_ actual: String, _ expected: String) -> Bool` (constant-time compare)`}`.

- [ ] **Step 1: Write the failing tests** — `validatesHttpsUrl` (`http://x` → `notHTTPS`, `garbage` → `invalidURL`), `validatesPin` (valid 32-byte base64 ok; 31 bytes/not base64 → `invalidPin`), `validatesToken` (63 and 65 hex chars, uppercase hex, missing prefix → `invalidToken`), `tokenNeverAppearsInIssueDescription`; `SPKIPinTests`: `matchesCryptoKitDerHash` (generate `P256.Signing.PrivateKey()` at run time; expected = `base64(SHA256(publicKey.derRepresentation))`; actual = `SPKIPin.hash(x963PublicKey: publicKey.x963Representation)`; equal), `rejectsWrongLengthKey`, `rejectsNonUncompressedPoint`, `matchesIsFalseForDifferentPin`, `inMemoryStoreRoundTripsToken`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** as specified. SHA-256 via `CryptoKit.SHA256` (system framework).
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add agent settings, token store and SPKI pin hashing"`.

### Task 11: Pinned HTTP client — `AgentAPI`

**Files:**
- Create: `WardenApp/Sources/Services/{AgentAPI,HTTPAgentAPI,PinnedURLSession}.swift`, `WardenApp/Tests/{HTTPAgentAPITests}.swift`, `WardenApp/Tests/Support/FakeHTTPTransport.swift`

**Interfaces:**
- Consumes: `AgentSettings`, `SecretStoring`, `SPKIPin`, `AccessEvent.uploadPayload`.
- Produces:
  - `enum PolicyFetchResult: Equatable, Sendable { case modified(body: Data, etag: String, version: Int64), notModified }`.
  - `enum AgentAPIError: Error, Equatable { notConfigured, unauthorized, throttled(retryAfter: Duration), invalidBatch, server(Int), transport, pinMismatch, malformedResponse }` — no case carries the token, URL query or response body text.
  - `protocol AgentAPI: Sendable { func fetchPolicy(etag: String?) async throws -> PolicyFetchResult; func postEvents(_ events: [AccessEvent]) async throws }`.
  - `protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }` and `PinnedURLSession: HTTPTransport` — `URLSession` with a delegate implementing the **async** `urlSession(_:didReceive:) async -> (URLSession.AuthChallengeDisposition, URLCredential?)`: for `NSURLAuthenticationMethodServerTrust` take the leaf certificate (`SecTrustCopyCertificateChain`), accept (`.useCredential`, `URLCredential(trust:)`) only when `SPKIPin.hash(of:)` matches the configured pin, else `.cancelAuthenticationChallenge`; maps a cancelled challenge to `AgentAPIError.pinMismatch` and other `URLError`s to `.transport`; ephemeral configuration, no cache, 15 s timeout, no redirects followed.
  - `struct HTTPAgentAPI: AgentAPI` — `init(settings: @Sendable () -> AgentSettings, secrets: any SecretStoring, transport: any HTTPTransport)`. `fetchPolicy`: `GET /api/v1/policy` with `Authorization: Bearer`, `If-None-Match` when given; `200` requires media type `application/json` (parse the header before `;`), body ≤ 1 MiB, JSON object whose `version` equals N in `ETag: "vN"` (accept the weak form), else `malformedResponse`; `304` → `.notModified`; `401` → `.unauthorized`; `429` → `.throttled(Retry-After seconds, default 60)`; `5xx` → `.server`. `postEvents`: `POST /api/v1/events`, `Content-Type: application/json`, `400` → `.invalidBatch`, same other mappings; empty array is a no-op.

- [ ] **Step 1: Write the failing tests** (fake transport capturing requests): `fetchSendsBearerAndIfNoneMatch`, `ok200ReturnsBodyEtagVersion`, `weakEtagIsAccepted`, `notModified304`, `versionMismatchWithEtagIsMalformed`, `invalidJsonBodyIsMalformed`, `wrongMediaTypeIsMalformed` and `charsetSuffixIsAccepted`, `bodyOverOneMiBIsMalformed`, `status401Unauthorized`, `status429UsesRetryAfter` and `429WithoutHeaderDefaultsTo60s`, `status503IsServerError`, `missingTokenIsNotConfigured`, `postEventsSendsBatchBody` (assert path, method, header, decoded body), `post400IsInvalidBatch`, `postEmptyIsNoOp` (no request sent), `errorsNeverContainToken` (token string absent from `String(describing:)` of every error), `pinMismatchSurfaces` (fake transport throws a cancelled `URLError` → `.pinMismatch`).
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** the API client and `PinnedURLSession`; the delegate class is the single boundary file, kept minimal (the pin decision itself is `SPKIPin.matches`, already tested).
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add SPKI-pinned agent API client"`.

### Task 12: `PolicySyncService` and `EventUploader`

**Files:**
- Create: `WardenApp/Sources/Services/{ExtensionLinking,PolicySyncService,EventUploader}.swift`, `WardenApp/Tests/{PolicySyncServiceTests,EventUploaderTests}.swift`, `WardenApp/Tests/Support/{FakeAgentAPI,FakeExtensionLink,ManualClock}.swift`

**Interfaces:**
- Consumes: `AgentAPI`, `AgentAPIError`.
- Produces:
  - `protocol ExtensionLinking: Sendable { func apply(policy: Data) async throws -> Int64; func currentPolicyVersion() async throws -> Int64; func drainEvents(max: Int) async throws -> [AccessEvent]; func liveEvents() -> AsyncStream<AccessEvent> }` (real implementation in Task 13).
  - `enum SyncState: Equatable, Sendable { notConfigured, idle, synced(version: Int64, at: Date), unreachable(lastVersion: Int64?), unauthorized, throttled(until: Date), extensionUnavailable(version: Int64) }`.
  - `actor PolicySyncService` — `init(api:, link:, clock: any Clock<Duration>, now: @Sendable () -> Date, interval: Duration = .seconds(10))`; `nonisolated let states: AsyncStream<SyncState>`; `func run() async` (loop: `syncOnce()`, sleep `interval`, until cancelled; `unauthorized` pauses polling until `resume()`); `func syncNow() async`; `func resume()`. `syncOnce`: `fetchPolicy(etag:)` → `.modified` → `link.apply`; success stores `etag`, `version`, last body; `apply` failure → state `extensionUnavailable`, etag cleared so the next tick re-pushes; `.notModified` → compare `link.currentPolicyVersion()` with the last version and re-push the stored body when they differ (extension restarted); `throttled` → state with `until`, next sleep = `retryAfter`; `server`/`transport`/`pinMismatch`/`malformedResponse` → `unreachable(lastVersion:)`, last good policy stays enforced; `unauthorized` → stop polling.
  - `actor EventUploader` — `init(api:, link:, clock:, interval: Duration = .seconds(5), maxPending: Int = 5000)`; `func run() async`; `func flushNow() async`; `var pendingCount: Int`. Each tick: `link.drainEvents(max: 500)` into `pending` (drop oldest beyond `maxPending`), then send batches of ≤ 500; success removes the batch; `server`/`transport`/`throttled`/`pinMismatch` keep it for the next tick (throttled waits `retryAfter`); `invalidBatch` drops that batch; `unauthorized` stops uploading until `resume()`.

- [ ] **Step 1: Write the failing tests** — Sync: `FirstFetchPushesToExtension`, `SecondTickSendsIfNoneMatch`, `NotModifiedKeepsState`, `ExtensionRestartRepushesWhenVersionsDiffer`, `ApplyFailureShowsExtensionUnavailableAndRetries`, `ServerDownKeepsLastGoodPolicy` (state `unreachable(lastVersion: 2)`, no apply call), `UnauthorizedStopsPollingUntilResume`, `ThrottleWaitsRetryAfter`, `MalformedResponseDoesNotReplacePolicy`, `SyncNowTriggersImmediateFetch`. Uploader: `UploadsDrainedEventsInOrder`, `BatchesAreAtMost500` (1200 events → 3 calls of 500/500/200), `KeepsBatchOnServerError`, `DropsBatchOnInvalidEvents`, `UnauthorizedStopsUploading`, `PendingIsBoundedAndDropsOldest` (10 000 events, `maxPending` 5000), `ThrottledWaitsRetryAfter`, `EmptyDrainSendsNothing`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** both actors with the injected clock only (no `Task.sleep` without it).
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` (repeat 3×) → Expected: PASS, no flakes.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add policy sync and event upload services"`.

### Task 13: Extension link (XPC client), extension manager, notifications

**Files:**
- Create: `WardenApp/Sources/Services/{ExtensionLink,ExtensionManager,ExtensionState,NotificationPoster,BlockNotifier}.swift`, `WardenApp/Tests/{ExtensionLinkTests,ExtensionStateTests,BlockNotifierTests}.swift`, `WardenApp/Tests/Support/FakeXPCConnection.swift`
- Modify: `Project.swift` (link `SystemExtensions`, `UserNotifications`), `WardenApp/Sources/Entry/WardenApp.swift` (temporary Install/Uninstall menu items for the Task 9 VM gate)

**Interfaces:**
- Consumes: `ExtensionLinking` (Task 12), `WardenExtensionXPC`, `WardenClientXPC`.
- Produces:
  - `protocol XPCConnectionProviding: Sendable { func connect() -> any XPCSession }`, `protocol XPCSession: Sendable { var service: any WardenExtensionXPC { get }; func interruptions() -> AsyncStream<Void> /* yields on interruption or invalidation */; func invalidate() }` — a thin wrapper over `NSXPCConnection(machServiceName: BundleIDs.machService, options: .privileged)` (the only callback code, handlers bridged to `AsyncStream`), exported object = a `WardenClientXPC` that yields decoded events into the link's stream.
  - `actor ExtensionLink: ExtensionLinking` — `init(provider:, clock:, callTimeout: Duration = .seconds(5))`; every call races the XPC call against `callTimeout` (task group) and throws `ExtensionLinkError.unavailable` on timeout/interruption; after an interruption/invalidation it reconnects on the next call and re-sends `subscribe`.
  - `enum ExtensionState: Equatable, Sendable { unknown, notInstalled, awaitingApproval, active, failed(String) }`; pure reducer `ExtensionState.reduce(_ state, event: ExtensionRequestEvent)` for `ExtensionRequestEvent { finished(rebootNeeded: Bool), failed(code: Int), needsApproval, propertiesActive(Bool) }`.
  - `protocol ExtensionManaging: Sendable { func refresh() async; func install() async; func uninstall() async; nonisolated var states: AsyncStream<ExtensionState> { get } }` and `ExtensionManager` — runs `OSSystemExtensionRequest` activation/deactivation/properties requests; the delegate object turns callbacks into `ExtensionRequestEvent` through an `AsyncStream` continuation (single boundary), always replies `.replace` to `actionForReplacing`.
  - `protocol NotificationPosting: Sendable { func requestAuthorization() async; func postBlock(process: String, file: String) async }` and `UserNotificationPoster` (async `UNUserNotificationCenter` APIs, title "Access blocked", file name only in the body — not the full path).
  - `struct BlockNotifier` — `func run(events: AsyncStream<AccessEvent>) async` posts only for `.deny` events.

- [ ] **Step 1: Write the failing tests** — Link: `ForwardsApplyAndReturnsVersion`, `TimeoutThrowsUnavailable` (service never replies; advance `ManualClock` 5 s), `InterruptionThrowsThenReconnectsAndResubscribes`, `LiveEventsAreDecodedFromClientCallback`, `DrainDecodesEvents`. State reducer: `FinishedWithoutRebootIsActive`, `NeedsApprovalIsAwaitingApproval`, `FailureCode4MapsToReadableMessage` (ADR-0001: bundle-not-found), `FailureCode9MapsToUsageDescriptionMessage`, `DeactivationFinishedIsNotInstalled`, `PropertiesInactiveIsNotInstalled`. Notifier: `PostsOnlyForDeny`, `BodyContainsFileNameNotFullPath`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** the types; keep `NSXPCConnection`/`OSSystemExtensionRequestDelegate`/`UNUserNotificationCenter` code in the three smallest boundary files.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add XPC extension link, system extension manager and block notifications"`.
- [ ] **Step 6: [owner, VM] smoke gate for Tasks 9 and 13.** Owner restores the `es-ready` snapshot, copies `build/…/WardenApp.app` into the guest, presses the temporary `Install extension` menu item, approves it in System Settings and grants Full Disk Access. In the guest: put a hand-made policy at `/Library/Application Support/Warden/policy.json` (one rule, target `**/.env`, matcher `{"path":"/bin/cat"}`; the cache is read at extension start, so restart the extension or reboot once); then `systemextensionsctl list` shows `[activated enabled]`, `cat /tmp/x/.env` → `Operation not permitted`, `cat` on another file succeeds, `sudo kill -9 <ext pid>` → the extension is back and denies again. The owner pastes the outputs. Record the observed ES path form (`/tmp/…` or `/private/tmp/…`) and, if it contradicts the bridge's normalization, add a test to Task 2's suite and a note to ADR-0001.
- [ ] **Step 7: Push and open PR C** (`feat: Endpoint Security adapter and app services`). **Ask the owner before merging.**

### Task 14: Design system — tokens and components

**Files:**
- Create: `scripts/tokens.py`, `scripts/test_tokens.py`, `WardenApp/Sources/DesignSystem/{Tokens,StatusHeader,EventRow,Badge,PolicyChip,WDButton}.swift`, `WardenApp/Sources/ViewModels/EventRowModel.swift`, `WardenApp/Tests/EventRowModelTests.swift`
- Modify: `.github/workflows/ci.yml` (job `tokens` on `ubuntu-24.04`, python 3.9: `python3 -I -B -m unittest discover -s scripts` is already in `macos-quality`; `tokens` runs `python3 -I -B scripts/tokens.py --check`)

**Interfaces:**
- `scripts/tokens.py [--check]` mirrors `warden-server/scripts/tokens.py`: runs `external/warden-core/design-tokens/generate.py` with `--css` into a temporary directory (so the submodule stays clean — the known `--css`-only quirk) and `--swift WardenApp/Sources/DesignSystem/Tokens.swift`; `--check` exits 1 when the committed file is missing or stale.
- Produces SwiftUI components (macOS 15, each with `#Preview` in light and dark via `.preferredColorScheme`): `StatusHeader(title: String, isOn: Bool)` (title + ON/OFF `Badge`), `Badge(_ text: String, kind: BadgeKind)` with `enum BadgeKind { case blocked, ok, neutral }` (danger/success/neutral tokens), `EventRow(model: EventRowModel)`, `PolicyChip(_ text: String)`, `WDButton(_ title: String, style: WDButtonStyle = .primary, action: @escaping @MainActor () -> Void)` (`enum WDButtonStyle { primary, secondary }`). Colors/fonts/spacing only from `Tokens` (no literals); mockup A "Native Calm".
- `struct EventRowModel: Identifiable, Equatable { let id: UUID; let title: String /* "Chrome → .env" */; let subtitle: String /* "~/proj/api/.env · 12 s ago" */; let badge: BadgeKind; let badgeText: String }` with `init(event: AccessEvent, now: Date, home: String)`: process name = last path component of `process.path` (or the responsible's when the opener is a helper and the responsible resolves), file shown as last component in the title, full path with `home` replaced by `~` in the subtitle, relative time via a pure formatter (`"just now"`, `"12 s ago"`, `"3 min ago"`, `"2 h ago"`).

- [ ] **Step 1: Write the failing tests** — `EventRowModelTests`: `deniedEventShowsBlockedBadge`, `allowedEventShowsOkBadge`, `subtitleReplacesHomeWithTilde`, `helperProcessUsesResponsibleName`, `relativeTimeBuckets` (0 s, 12 s, 3 min, 2 h), `unknownProcessNameFallsBack` (empty path → "Unknown process"); `scripts/test_tokens.py`: `test_check_fails_when_file_missing`, `test_check_passes_after_generation`, `test_generation_leaves_submodule_clean` (git status of `external/warden-core` unchanged).
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh`, unittest → Expected: FAIL.
- [ ] **Step 3: Implement** the script (run it once to create `Tokens.swift`; commit the generated file), the model and the components.
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh`, `python3 -I -B scripts/tokens.py --check`, `scripts/build.sh` → Expected: PASS; open the previews in Xcode **[owner, optional]** and confirm light and dark render (Claude cannot view them).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add design tokens and SwiftUI components"`. After PR D merges, **ask the owner** to re-apply rulesets with the extra `tokens` check (`bootstrap-repo.sh warden-macos "<description>" macos-build macos-quality tokens`).

### Task 15: `AppStateStore` and ViewModels

**Files:**
- Create: `WardenApp/Sources/ViewModels/{AppStateStore,PopoverViewModel,SettingsViewModel,EventsViewModel,RelativeTime}.swift`, `WardenApp/Tests/{AppStateStoreTests,PopoverViewModelTests,SettingsViewModelTests,EventsViewModelTests}.swift`

**Interfaces:**
- Consumes: `SyncState`, `ExtensionState`, `ExtensionManaging`, `PolicySyncService`, `SettingsStoring`, `SecretStoring`, `AgentSettings.validate`, `EventRowModel`, `ExtensionLinking.liveEvents`.
- Produces (`@MainActor @Observable final class`):
  - `AppStateStore` — `init(sync: AsyncStream<SyncState>, extensionStates: AsyncStream<ExtensionState>, events: AsyncStream<AccessEvent>, now: @Sendable () -> Date)`; properties `syncState`, `extensionState`, `events: [AccessEvent]` (newest first, capped at 500); `func run() async` merges the three streams in a task group.
  - `PopoverViewModel(store:, syncNow: @Sendable () async -> Void, openSettings: @MainActor () -> Void, openEvents: @MainActor () -> Void, now:)` — `isProtectionActive` (extension `.active` **and** sync state carries a version), `statusTitle` ("Protection active" / "Protection off" / "Awaiting approval in System Settings" / "Extension not installed"), `policyLine` ("Policy v2 · synced 4 s ago" / "Policy v2 · server unreachable" / "No policy yet" / "Check agent token" for unauthorized), `recentRows: [EventRowModel]` (5 newest), `syncNowTapped()`.
  - `SettingsViewModel` — editable `serverURLText`, `pinText`, `tokenText`; `issues` (live validation, never echoes the token); `save()` (writes settings, token to `SecretStoring`, clears `tokenText`, resumes sync); `extensionStateText`; `installTapped()`, `uninstallTapped()`; `canSave`.
  - `EventsViewModel` — `blockedOnly: Bool`, `rows: [EventRowModel]` filtered.

- [ ] **Step 1: Write the failing tests** — Store: `AppliesStreamsAndCapsEvents` (600 events → 500, newest first). Popover: `activeWhenExtensionActiveAndPolicySynced`, `offWhenExtensionNotInstalled`, `awaitingApprovalMessage`, `policyLineSynced` (`synced(2, at: now-4s)` → "Policy v2 · synced 4 s ago"), `policyLineUnreachableKeepsVersion`, `unauthorizedShowsCredentialHint`, `recentRowsAreFiveNewest`, `syncNowCallsService`. Settings: `invalidFieldsDisableSave`, `saveStoresTokenAndClearsField`, `saveWritesSettingsAndResumesSync`, `issuesNeverContainToken`, `installAndUninstallDelegateToManager`. Events: `blockedOnlyFiltersAllowEvents`.
- [ ] **Step 2: Run to verify they fail** — `scripts/test.sh` → Expected: FAIL.
- [ ] **Step 3: Implement** the types; time formatting reuses Task 14's formatter (move it into `RelativeTime.swift` if Task 14 placed it elsewhere).
- [ ] **Step 4: Run to verify they pass** — `scripts/test.sh` → Expected: PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add app state store and view models"`.

### Task 16: Views, scenes and app wiring

**Files:**
- Create: `WardenApp/Sources/Views/{PopoverView,SettingsView,EventsWindowView}.swift`, `WardenApp/Sources/Entry/AppEnvironment.swift`
- Modify: `WardenApp/Sources/Entry/WardenApp.swift` (replace the Task 13 temporary items)

**Interfaces:**
- Consumes: everything above.
- Produces: `PopoverView` per mockup A (`StatusHeader`, policy line + "Sync now" `WDButton`, up to five `EventRow`s, footer "All events…" / "Settings"); `SettingsView` (server URL, `SecureField` token, pin, validation messages, Save, Install/Uninstall extension, extension state line); `EventsWindowView` (list + "Blocked only" toggle). `@main struct WardenApp: App` — `MenuBarExtra { PopoverView } label: { Image(systemName: "shield.lefthalf.filled") }` with `.menuBarExtraStyle(.window)`, `Window("All events", id: "events")`, `Window("Settings", id: "settings")`. `AppEnvironment` (`@MainActor`) builds the real object graph: `UserDefaultsSettingsStore`, `KeychainSecretStore`, `PinnedURLSession`, `HTTPAgentAPI`, `ExtensionLink`, `PolicySyncService`, `EventUploader`, `ExtensionManager`, `BlockNotifier`, `AppStateStore`; starts the long-running services in `.task` of the app and cancels them on termination. Views contain no logic beyond bindings.

- [ ] **Step 1: Write the failing check.** Views and wiring have no unit tests (their logic lives in the tested ViewModels and services). Replace the stub `WardenApp.swift` body with references to `PopoverView`, `SettingsView`, `EventsWindowView`, `AppEnvironment`; run `scripts/build.sh` → Expected: FAIL (types missing).
- [ ] **Step 2: Implement** views and wiring.
- [ ] **Step 3: Verify** — `scripts/lint.sh && scripts/test.sh && scripts/build.sh` → Expected: all green, no warnings. **[owner]** launches the built app on the host *without* activating the extension (UI check only: menu bar icon, popover, Settings validation, "Extension not installed" state) and reports with a screenshot; the extension is never installed on the host.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: add menu bar popover, settings and events window"`.

### Task 17: PR E gate

**Files:** none new.

- [ ] **Step 1:** `scripts/lint.sh && scripts/coverage.sh && python3 -I -B scripts/tokens.py --check` → Expected: exit 0; include the per-file coverage table in the PR description.
- [ ] **Step 2:** Run the requesting-code-review pass on the branch diff; fix findings as separate `fix:` commits.
- [ ] **Step 3: Push and open PR D** (`feat: design system and app UI`). **Ask the owner before merging**; then ask about re-applying the rulesets with `tokens`.

### Task 18: Documentation and the e2e checklist

**Files:**
- Create: `docs/e2e-checklist.md`
- Modify: `README.md` (what it is, mermaid architecture diagram of §4, quick start in the VM, limitations from ADR-0001, roadmap per spec §2 non-goals: paid certificate → notarization → installer, tamper protection, NetworkExtension, content inspection, Windows agent, MDM), `docs/adr/0001-adhoc-signed-es-extension.md` (append a "Verified in Plan 4" section with ES path form, FDA requirement and measured fail-open window once the owner reports them), `CLAUDE.md` (build/test commands)

**Interfaces:** `docs/e2e-checklist.md` has numbered, checkable steps with expected results for: (1) VM prep (snapshot `es-ready`, `docs/vm-setup.md`); (2) build and sign (`scripts/build.sh`), copy into the guest; (3) activate, approve in System Settings, grant Full Disk Access, `systemextensionsctl list`; (4) Settings: server URL, SPKI pin, token — values come from the owner's password manager, **never written into the repo**; (5) the six §9 scenario steps verbatim with expected outputs (`Policy v2` within ≤ 15 s, drag `~/proj/api/.env` into the browser chat → denied + notification + popover + panel event, `cat` still works, python3 blocklist → v3 → `PermissionError`, `sudo kill -9` restart and restore v3 from cache); (6) clean snapshot → install → verify; (7) result table (date, build, pass/fail, notes) filled by the owner each release.

- [ ] **Step 1: Write the docs.** There is no test for prose; the check is `gitleaks detect --no-git` on the tree, and a link check by eye of the README.
- [ ] **Step 2: Verify** — `pre-commit run --all-files` → Expected: all hooks pass.
- [ ] **Step 3: Commit** — `git add -A && git commit -m "docs: add e2e checklist, README architecture and roadmap"`.

### Task 19: Acceptance run, release v0.1.0

**Files:** `docs/e2e-checklist.md` (result row), `docs/adr/0001-…` (verified section).

- [ ] **Step 1: Push and open PR E** (`docs: e2e checklist, README and ADR update`). **Ask the owner before merging.**
- [ ] **Step 2: [owner, VM] Run the full checklist** on the `es-ready` snapshot against the live VPS (`https://185.238.74.103:8443`, pin `+i3lgexYewYNsJH5ir99x3hqli2aKsadtxLyWYqJ6ho=`, token from the password manager entered in Settings). Owner pastes the outputs (no secrets). If a step fails, stop and use superpowers:systematic-debugging; fix on a `fix/WRD-<n>-…` branch with a regression test where the logic is testable.
- [ ] **Step 3:** Record the result row and the measured values (ES path form, FDA requirement, fail-open window) in the checklist and ADR-0001; commit `docs: record v0.1 acceptance run`.
- [ ] **Step 4: Release** — **ask the owner**, then PR `develop → main` (merge commit allowed on `main`), `git pull --ff-only`, verify `git rev-parse main origin/main` are equal **before** tagging, `git tag -a v0.1.0 -m "v0.1.0"`, push the tag (the owner pushes it with `!` if the auto-mode classifier blocks it). Update `HANDOFF.md` state section.
