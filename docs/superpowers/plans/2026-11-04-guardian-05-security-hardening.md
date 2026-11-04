# Guardian Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the findings of the 2026-11-04 security audit: the local XPC bypass, the path-matching bypasses, the admin brute-force path, the agent-configuration integrity gap, and the missing SAST/SCA stages in CI.

**Architecture:** Three independent repositories are touched and every task is self-contained, so each task becomes its own PR in its own repository. Task order is by risk and by cost: cheap server and CI work first, then the two matching/identity changes in core, then the macOS client. No task depends on another task's interfaces except Task 5, which consumes the normalization added in Task 4.

**Tech Stack:** C++20 (guardian-core, guardian-server, cpp-httplib, OpenSSL, nlohmann/json), Swift 6 with Swift Concurrency and Endpoint Security (guardian-macos), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-20-guardian-design.md` for the product behaviour each task must preserve. The audit findings this plan implements are recorded in `## Findings` below; there is no separate spec document.

## Findings

Severity is the audit's, repeated here so a task's reviewer can weigh it without the chat log.

| # | Severity | Finding | Task |
|---|----------|---------|------|
| 1 | High | XPC peer requirement checks only the bundle identifier; under ad-hoc signing any local process can impersonate the app, apply an empty policy and drain events | 5 |
| 2 | High | Path matching is lexical and case-sensitive: case, Unicode normalization, the `/System/Volumes/Data` firmlink and hard links all defeat a deny rule | 4 |
| 3 | High | Only `ES_EVENT_TYPE_AUTH_OPEN` is subscribed; clone, copyfile, rename and truncate are not mediated | 7 |
| 4 | Medium | `AuthThrottle` evicts the oldest key at `kMaxKeys`, so a flood of distinct source addresses clears an active lockout and restores unlimited admin password attempts | 1 |
| 5 | Medium | Server URL and SPKI pin live in `UserDefaults`; a process running as the user redirects the agent and harvests its bearer token | 6 |
| 6 | Low | `adminCredentialsMatch` returns early on a length mismatch, leaking the admin password length | 2 |
| 7 | Low | No HSTS; CSP omits `object-src`, `base-uri` and `form-action` | 3 |
| 8 | Low | No SAST (CodeQL) and no SCA (OSV-Scanner); Dependabot covers only `github-actions`, leaving vcpkg's OpenSSL and the `external/guardian-core` submodule unscanned | 3 |
| 9 | Low | Actions are pinned to major tags, not commit SHAs; the gitleaks release tarball is used without checksum verification | 3 |

Out of scope, with rationale:

- **Symlinks.** Endpoint Security resolves a symlink before it reports `es_file_t.path`, so the path the engine sees is already the target's. Nothing to do.
- **Hard links.** A hard link is a second genuine name for one inode, and no amount of path normalization catches it. Closing it means matching on `(st_dev, st_ino)` and therefore an engine that takes a file identity rather than a path, plus a policy language that can express one. That is a design change, not a fix: it needs its own ADR before any code.
- **Shared admin password, no sessions, no admin audit trail.** Single-operator deployment is the design's current assumption (design §4). Revisit when there is a second operator.

## Global Constraints

- TDD: the failing test is written and seen to fail before the implementation, in every task.
- Branches: `feature/GRD-<n>-<slug>`, `fix/…` or `chore/…`; never commit to `main` or `develop`; PRs target `develop`. Never `--no-verify`, never force push.
- Conventional Commits.
- Warnings are errors in every language.
- Swift: Swift Concurrency only; no force unwraps, no `try!`. The synchronous Endpoint Security handler is the only exception (design §7).
- No new dependency without an ADR in `docs/adr/`.
- Docs and comments in English.
- Coverage gate stays at 80% minimum line coverage.
- Secrets: never read or commit `.env*` (except `.env.example`), `*.pem`, `*.key`, `*.p12`, `*.cer`, `config.local.json`.

## Review Focus

Input classes the audit implies that no single task's tests naturally reach. Each line's test is assigned to the task that owns the code.

- A lockout that expires while the throttle is at `kMaxKeys` must still expire, not become permanent: eviction protection must not pin a stale entry forever (Task 1).
- A path whose case-folded form collides with another real file must not silently widen a deny rule beyond the volume's own semantics: folding is per-rule matching, never a rewrite of the stored path (Task 4).
- A path containing invalid UTF-8 must not throw or truncate inside normalization; the engine's contract is `noexcept` for matching and it must fail closed (Task 4).
- An XPC peer that satisfies the requirement string but dies mid-call must not leave a subscribed client in the hub (Task 5).
- A configuration file that is unreadable or owned by the wrong user must stop the agent from talking to any server, not fall back to `UserDefaults` (Task 6).

---

## Task 1: Admin lockout survives key-table pressure

**Repository:** guardian-server

**Files:**
- Modify: `src/auth.hpp:34-62` (add the admin-realm counter and the eviction guard)
- Modify: `src/auth.cpp:106-126` (`recordFailure`)
- Modify: `src/api.cpp:96-116` (`authenticateWith`)
- Test: `tests/auth_test.cpp`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `AuthThrottle::blocked(const std::string& key)` and `recordFailure` keep their signatures. New: `AuthThrottle(NowFn now, int maxFailures = 5, std::chrono::seconds lockout = std::chrono::seconds(60), int globalMaxFailures = 50)`; the realm-wide counter is internal and keyed by the realm prefix of `key` (the text before `'|'`).

- [ ] **Step 1: Write the failing tests**

```cpp
TEST_CASE("a lockout is not cleared by flooding the key table") {
  // 5 failures from one address, then kMaxKeys failures from distinct addresses,
  // then the original address is still blocked.
}

TEST_CASE("the admin realm locks out after globalMaxFailures across addresses") {
  // 50 failures, each from a different address, in realm "admin";
  // a 51st address is blocked without presenting credentials.
}

TEST_CASE("a global lockout expires after the lockout window") {
  // after globalMaxFailures, advance the clock past `lockout`: a new address is served again.
}

TEST_CASE("a locked entry that is never evicted still expires") {
  // one address is locked, the table is then filled to kMaxKeys from distinct
  // addresses; after the clock passes `lockout` that address is served again,
  // so eviction protection never pins an entry permanently.
}

TEST_CASE("the agent realm has no global lockout") {
  // 200 failures from distinct addresses in realm "agent"; a fresh address is not blocked.
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cmake --build --preset macos && ctest --preset macos -R auth`
Expected: FAIL — the first test blocks nobody, the second compiles against a constructor that has no fourth parameter.

- [ ] **Step 3: Implement the eviction guard and the realm counter**

In `recordFailure`, skip entries that are currently locked when choosing a victim from `order_`, and when every candidate is locked, refuse to insert rather than evict (the new key then counts against the realm counter only). The realm counter is a separate `std::unordered_map<std::string, Entry>` keyed by the realm, incremented on every failure in realm `admin`, consulted by `remainingLocked` before the per-address entry, and reset by `recordSuccess` for that realm. Only realm `admin` has a global limit; pass `globalMaxFailures = 0` to disable it, and construct the agent realm's throttle that way in `main.cpp`.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `ctest --preset macos -R auth`
Expected: PASS

- [ ] **Step 5: Document the contract**

Update the `AuthThrottle` comment in `src/auth.hpp:33` to state both limits and that a locked entry is never evicted, and `docs/api.md`'s 429 section to say that the admin realm throttles globally.

- [ ] **Step 6: Commit**

```bash
git add src/auth.hpp src/auth.cpp src/api.cpp src/main.cpp tests/auth_test.cpp docs/api.md
git commit -m "fix: keep admin lockouts under key-table pressure"
```

---

## Task 2: Admin password comparison is length-independent

**Repository:** guardian-server

**Files:**
- Modify: `src/auth.cpp:71-77` (`adminCredentialsMatch`)
- Test: `tests/auth_test.cpp`

**Interfaces:**
- Consumes: `sha256Hex`, `constantTimeEquals` from `src/crypto.hpp` (unchanged).
- Produces: `adminCredentialsMatch` keeps its signature and `noexcept`.

- [ ] **Step 1: Write the failing test**

```cpp
TEST_CASE("credentials are compared over fixed-length digests") {
  // a password one byte shorter than the expected one, and one 4096 bytes long,
  // both return false; the correct password returns true; an empty expected
  // password returns false for any candidate.
}
```

The timing property itself is not unit-testable; the test pins behaviour, and the digest comparison is what makes the timing length-independent.

- [ ] **Step 2: Run the test and watch it fail**

Run: `ctest --preset macos -R auth`
Expected: FAIL on the 4096-byte case only after the implementation changes — if it already passes, keep it as a regression test and go to Step 3.

- [ ] **Step 3: Compare digests instead of raw strings**

`constantTimeEquals(sha256Hex(credentials.password), sha256Hex(expectedPassword))`, with the user comparison and the non-empty check unchanged and still unconditional. Note in the comment that both operands are now 64 bytes regardless of input length.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `ctest --preset macos -R auth`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/auth.cpp tests/auth_test.cpp
git commit -m "fix: compare admin credentials over fixed-length digests"
```

---

## Task 3: Response headers, SAST and SCA

**Repository:** guardian-server first, then the same CI files in guardian-core and guardian-macos

**Files:**
- Modify: `src/static_files.cpp:20-56` (CSP)
- Modify: `src/api.cpp:35-38` (`addCommonHeaders`)
- Modify: `src/http_server.cpp:182-261` (pass a "TLS is on" flag to `Api`)
- Modify: `src/api.hpp:34-41` (`ApiDeps`)
- Test: `tests/api_test.cpp`, `tests/static_files_test.cpp`
- Create: `.github/workflows/codeql.yml`, `.github/workflows/osv.yml` (in all three repositories)
- Modify: `.github/dependabot.yml`, `.github/workflows/*.yml` (SHA pins), `.github/workflows/gitleaks.yml` (checksum)

**Interfaces:**
- Consumes: nothing.
- Produces: `ApiDeps` gains `bool tlsEnabled = false`; `HttpServer::bind` sets it from `options_.tls.has_value()`.

- [ ] **Step 1: Write the failing tests**

```cpp
TEST_CASE("HSTS is sent only when TLS is enabled") {
  // tlsEnabled == true  -> "Strict-Transport-Security: max-age=31536000"
  // tlsEnabled == false -> the header is absent (loopback HTTP must stay usable)
}

TEST_CASE("the panel CSP forbids objects, base rewriting and form posts") {
  // GET "/" carries: default-src 'self'; frame-ancestors 'none';
  //                  object-src 'none'; base-uri 'none'; form-action 'none'
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `ctest --preset macos -R "api|static"`
Expected: FAIL — `ApiDeps` has no `tlsEnabled`, and the CSP string lacks the three directives.

- [ ] **Step 3: Add the headers**

`addCommonHeaders` sets `Strict-Transport-Security: max-age=31536000` when `deps.tlsEnabled`; `kAllowlist`'s HTML entry carries the extended CSP. No `includeSubDomains` and no `preload`: the server is one host on a fixed port.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `ctest --preset macos`
Expected: PASS

- [ ] **Step 5: Add CodeQL**

`.github/workflows/codeql.yml`, on `pull_request` and on a weekly schedule, `security-events: write`, `languages: c-cpp` (guardian-core, guardian-server) and `swift` (guardian-macos). Build with the project's own preset via the manual build mode, so vcpkg and Tuist are honoured. Actions pinned by SHA.

- [ ] **Step 6: Add OSV-Scanner**

`.github/workflows/osv.yml`, on `pull_request` and monthly, scanning the manifest (`vcpkg.json` for the C++ repositories, `mise.toml` plus the submodule for guardian-macos), failing the job on a fixable advisory. Extend `.github/dependabot.yml` with the `git-submodule` ecosystem in guardian-macos and guardian-server.

- [ ] **Step 7: Pin the supply chain**

Replace every `uses: …@v<major>` with a commit SHA plus a `# v<major>` comment, in all workflows of all three repositories, `ilammy/msvc-dev-cmd` included. In `gitleaks.yml`, verify the tarball against a pinned `sha256sum` before extracting.

- [ ] **Step 8: Run the workflows on the branch and triage**

Run: push the branch and watch `codeql` and `osv` in the Actions tab.
Expected: both complete. Triage the first run's findings; suppress nothing without a one-line reason in the workflow or an ADR.

- [ ] **Step 9: Commit**

```bash
git add src/api.hpp src/api.cpp src/static_files.cpp src/http_server.cpp tests .github
git commit -m "ci: add CodeQL and OSV-Scanner, pin actions, tighten response headers"
```

---

## Task 4: Path matching resists case, Unicode and firmlink variants

**Repository:** guardian-core

**Files:**
- Modify: `include/guardian/path.hpp`, `src/path.cpp:16-60` (firmlink prefix, normalization helper)
- Modify: `include/guardian/glob.hpp:9-14`, `src/glob.cpp:34-57` (`segmentMatch`)
- Test: `tests/path_test.cpp`, `tests/glob_test.cpp`, `tests/engine_test.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: `std::string foldForMatching(std::string_view path)` in `guardian/path.hpp` — ASCII case-folded, NFC-normalized, with a leading `/System/Volumes/Data` stripped; invalid UTF-8 is passed through byte-wise unchanged. `globMatch` keeps its signature and becomes case-insensitive for ASCII; `Engine` applies `foldForMatching` to both the compiled patterns and the request path.

- [ ] **Step 1: Write the failing tests**

```cpp
TEST_CASE("matching ignores ASCII case") {
  // pattern "/Users/*/Secrets/**" matches "/users/x/secrets/f" and "/Users/X/SECRETS/F"
}

TEST_CASE("the data firmlink prefix is stripped") {
  // "/System/Volumes/Data/Users/x/Secrets/f" matches "/Users/*/Secrets/**"
  // and "/System/Volumes/Datastore/x" is NOT stripped (prefix must end at a segment boundary)
}

TEST_CASE("decomposed and composed names match the same rule") {
  // "/Users/x/Résumés/f" and "/Users/x/Résumés/f" both match "/Users/*/Résumés/**"
}

TEST_CASE("folding does not change stored or reported paths") {
  // normalizePath("/Users/X/Secrets/F") still returns it as written, and the
  // Decision carries the unfolded path, while the rule above still matches.
}

TEST_CASE("invalid UTF-8 neither throws nor matches more than it should") {
  // a path with a lone 0x80 byte: normalizePath and foldForMatching return,
  // globMatch stays noexcept, and Engine::isPotentiallyProtected returns true (fail closed)
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cmake --build --preset macos && ctest --preset macos`
Expected: FAIL — `foldForMatching` does not exist; the case tests fail against today's case-sensitive `segmentMatch`.

- [ ] **Step 3: Implement `foldForMatching`**

ASCII-only case folding (`A-Z` -> `a-z`; do not pull in ICU — a new dependency needs an ADR, and the design's targets are ASCII paths plus occasional Latin-1 user directory names). NFC composition for the Latin-1 Supplement and Latin Extended-A ranges only, via a static table in `src/path.cpp`, which is what APFS produces for European filenames. A byte sequence that is not valid UTF-8 is copied through unchanged. The firmlink prefix `/System/Volumes/Data` is stripped only when the next character is `/` or the string ends.

- [ ] **Step 4: Apply it in the engine, not in storage**

`Engine`'s constructor folds each compiled pattern; `evaluate` and `isPotentiallyProtected` fold the request path. `normalizePath` keeps returning the unfolded path, so stored policies and logged event paths stay as the user wrote them.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `ctest --preset macos && scripts/lint.sh && scripts/coverage.sh`
Expected: PASS, coverage at or above 80.

- [ ] **Step 6: Update the documented contract**

`glob.hpp:13` currently promises case-sensitive literal matching. Replace that sentence with the new rule, and note in `path.hpp` that folding is for matching only.

- [ ] **Step 7: Commit**

```bash
git add include/guardian src/path.cpp src/glob.cpp src/engine.cpp tests
git commit -m "fix: match paths case-insensitively and across firmlink and Unicode variants"
```

- [ ] **Step 8: Roll the submodule forward**

In guardian-macos, update `external/guardian-core` to this commit, run `scripts/test.sh`, and open that bump as its own PR.

---

## Task 5: XPC peers are pinned to the signing certificate

**Repository:** guardian-macos

**Files:**
- Modify: `DlpExtension/Sources/Logic/ExtensionService.swift:88-90` (`peerRequirement`)
- Modify: `GuardianApp/Sources/Services/MachServiceConnector.swift:7-9` (`peerRequirement`)
- Create: `Shared/PeerRequirement.swift` (one requirement builder for both sides)
- Modify: `Project.swift` (expose `GUARDIAN_TEAM_ID` to both targets)
- Test: `DlpExtension/Tests/PeerRequirementTests.swift`, `GuardianApp/Tests/PeerRequirementTests.swift`
- Modify: `docs/adr/0001-adhoc-signed-es-extension.md` (record the release gate)

**Interfaces:**
- Consumes: `BundleIDs` from `Shared/BundleIDs.swift`.
- Produces: `PeerRequirement.requirement(identifier: String, teamID: String?) -> String` — with a team ID, `anchor apple generic and identifier "<id>" and certificate leaf[subject.OU] = "<team>"`; without one, `identifier "<id>"` for local ad-hoc builds. `PeerRequirement.isReleaseSafe(_ requirement: String) -> Bool` is true only when the string contains `certificate leaf[subject.OU]`.

- [ ] **Step 1: Write the failing tests**

```swift
func testRequirementWithTeamIDPinsAnchorAndLeaf() { /* exact expected string */ }
func testRequirementWithoutTeamIDIsIdentifierOnly() { /* exact expected string */ }
func testIdentifierOnlyRequirementIsNotReleaseSafe() { /* isReleaseSafe == false */ }
func testReleaseBuildsUseAReleaseSafeRequirement() {
    // #if !DEBUG: XCTAssertTrue(PeerRequirement.isReleaseSafe(ExtensionService.peerRequirement()))
    // and the same for MachServiceConnector.peerRequirement()
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `scripts/test.sh`
Expected: FAIL — `PeerRequirement` does not exist.

- [ ] **Step 3: Implement `Shared/PeerRequirement.swift` and use it on both sides**

Read the team ID from the `GUARDIAN_TEAM_ID` build setting, surfaced through `Info.plist` so both the app and the extension see it. Both `peerRequirement()` functions become one-line calls. The extension pins the app's identifier, the app pins the extension's, as today.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `scripts/test.sh && scripts/lint.sh`
Expected: PASS. Without a team ID configured, `testReleaseBuildsUseAReleaseSafeRequirement` is the gate that fails a release build, which is the intent.

- [ ] **Step 5: Add the connection-loss regression test**

In `ExtensionServiceTests`, assert that a connection whose `invalidationHandler` fires removes its client from the hub, so `subscriberCount()` returns to its previous value (Review Focus, line 4).

- [ ] **Step 6: Record the gate in ADR-0001**

Add a "Release gate" section: ad-hoc signing stays for local development, a release requires `GUARDIAN_TEAM_ID`, and the test above is what enforces it.

- [ ] **Step 7: Commit**

```bash
git add Shared/PeerRequirement.swift DlpExtension GuardianApp Project.swift docs/adr/0001-adhoc-signed-es-extension.md
git commit -m "fix: pin XPC peers to the signing certificate, not just the identifier"
```

---

## Task 6: Server URL and pin come from a root-owned configuration

**Repository:** guardian-macos

**Files:**
- Create: `GuardianApp/Sources/Services/ManagedSettingsStore.swift`
- Modify: `GuardianApp/Sources/Services/AgentSettings.swift:63-94` (`SettingsStoring` conformance selection)
- Modify: `GuardianApp/Sources/Entry/AppEnvironment.swift` (pick the managed store when the file exists)
- Modify: `GuardianApp/Sources/ViewModels/SettingsViewModel.swift` (read-only form when managed)
- Create: `docs/managed-configuration.md`
- Test: `GuardianApp/Tests/ManagedSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `AgentSettings`, `AgentSettings.isCanonicalPin`, `AgentSettings.urlIssue`.
- Produces: `ManagedSettingsStore(fileURL: URL)` conforming to `SettingsStoring`, reading `/Library/Application Support/Guardian/settings.json` (`{"serverURL": …, "spkiPin": …}`); `save` is a no-op. `var isManaged: Bool` on `SettingsStoring`, `false` by default, `true` here.

- [ ] **Step 1: Write the failing tests**

```swift
func testLoadsURLAndPinFromAFileOwnedByRoot() { /* uid 0, mode 0644 or stricter -> settings */ }
func testRejectsAFileOwnedByAnotherUser() { /* -> AgentSettings(serverURL: nil, spkiPin: "") */ }
func testRejectsAWorldWritableFile() { /* mode 0666 -> empty settings */ }
func testRejectsANonCanonicalPinOrNonHTTPSURL() { /* -> empty settings */ }
func testSaveDoesNotWriteTheFile() { /* file bytes unchanged */ }
```

Ownership tests need a fixture file; create it in the test's temporary directory and skip the uid-0 case with `XCTSkipUnless(getuid() == 0)` so the suite stays runnable unprivileged, while CI's root VM covers it.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `scripts/test.sh`
Expected: FAIL — `ManagedSettingsStore` does not exist.

- [ ] **Step 3: Implement the store**

`stat` the file, require `st_uid == 0` and no group or other write bit, then decode and validate with the existing `AgentSettings` validators. Any failure returns empty settings, which `HTTPAgentAPI.authorizedRequest` already turns into `.notConfigured` — the agent then talks to nobody, which is the required fail-closed behaviour (Review Focus, line 5).

- [ ] **Step 4: Select the store at startup and lock the form**

`AppEnvironment` uses `ManagedSettingsStore` when the file exists and `UserDefaultsSettingsStore` otherwise. When `isManaged`, `SettingsViewModel` shows the URL and pin as read-only with a one-line explanation; the token field stays editable, because the token belongs to the user's Keychain.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `scripts/test.sh && scripts/lint.sh && scripts/coverage.sh`
Expected: PASS

- [ ] **Step 6: Write the operator documentation**

`docs/managed-configuration.md`: the file's path, its JSON shape, the required ownership and mode, the `install -o root -m 0644` command, and the fact that an invalid file disables the agent rather than falling back.

- [ ] **Step 7: Commit**

```bash
git add GuardianApp docs/managed-configuration.md
git commit -m "feat: read server URL and pin from a root-owned configuration file"
```

---

## Task 7: Mediate clone, copyfile, rename and truncate

**Repository:** guardian-macos

**Files:**
- Modify: `DlpExtension/Sources/ES/EndpointSecurityClient.swift:120-200` (subscription, dispatch, responses)
- Modify: `DlpExtension/Sources/Logic/OpenCoordinator.swift` (one entry point per mediated event)
- Modify: `Shared/AccessEvent.swift` (an `operation` field)
- Modify: `guardian-server` `src/event.cpp` and `web/app.js` to accept and display `operation` — separate PR in that repository, landed first
- Test: `DlpExtension/Tests/OpenCoordinatorTests.swift`, `DlpExtension/Tests/ESDeadlineTests.swift`, `GuardianApp/Tests/EventRowModelTests.swift`
- Create: `docs/adr/0004-mediated-es-events.md`

**Interfaces:**
- Consumes: `Engine.evaluate` and `Engine.isPotentiallyProtected` through `GDEngine` (unchanged).
- Produces: `AccessEvent.operation: Operation` (`open`, `clone`, `copyfile`, `rename`, `truncate`), defaulting to `.open` when a stored event omits it, so existing event files keep parsing. `OpenCoordinator.decide(operation:target:source:process:responsible:)` replaces the open-only entry point.

This task is the largest of the plan and carries a real performance risk: every added AUTH event is another synchronous decision on a hot kernel path. It earns its own ADR and its own measurement step.

- [ ] **Step 1: Write the ADR first**

`docs/adr/0004-mediated-es-events.md`: which events are mediated and why, which are deliberately not (`AUTH_MMAP` and `AUTH_EXEC`: every process start and every dylib load would pay the decision cost), how a two-path event (clone, copyfile, rename) is evaluated — deny when either source or destination matches a deny rule — and the deadline budget per event type.

- [ ] **Step 2: Write the failing tests**

```swift
func testCloneFromAProtectedSourceIsDenied() { }
func testCloneToAProtectedDestinationIsDenied() { }
func testCopyfileIsDecidedLikeClone() { }
func testRenameOutOfAProtectedDirectoryIsDenied() { }
func testTruncateOfAProtectedFileIsDenied() { }
func testAnUnprotectedPairIsAllowedAndCacheable() { }
func testEachMediatedEventRespectsItsDeadline() { }
func testStoredEventsWithoutOperationDecodeAsOpen() { }
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `scripts/test.sh`
Expected: FAIL — `decide(operation:…)` does not exist.

- [ ] **Step 4: Implement the coordinator entry point and the dispatch**

Subscribe to `ES_EVENT_TYPE_AUTH_CLONE`, `ES_EVENT_TYPE_AUTH_COPYFILE`, `ES_EVENT_TYPE_AUTH_RENAME` and `ES_EVENT_TYPE_AUTH_TRUNCATE` alongside `AUTH_OPEN`. Each handler extracts its paths from its own union member, calls `decide`, and answers with the response function that event type requires — `es_respond_flags_result` for open, `es_respond_auth_result` for the others. Keep per-file caching only where no path in the event is potentially protected.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `scripts/test.sh && scripts/lint.sh && scripts/coverage.sh`
Expected: PASS

- [ ] **Step 6: Measure on real hardware**

In the VM, per `docs/e2e-checklist.md`: a Spotlight reindex and an Xcode build with the extension loaded, with the diagnostics summary captured before and after. Record the per-event p50 and p99 in the ADR. If any event type exceeds its budget, drop that event type from the subscription in this PR and say so in the ADR rather than shipping a slow AUTH path.

- [ ] **Step 7: Extend the checklist and commit**

Add the new event types to `docs/e2e-checklist.md`.

```bash
git add DlpExtension Shared GuardianApp docs
git commit -m "feat: mediate clone, copyfile, rename and truncate"
```

---

## Suggested sequence

1. Tasks 1, 2 and 3 — guardian-server plus CI. One day. Nothing depends on them.
2. Task 4 — guardian-core, then the submodule bump. One to two days.
3. Task 5 — guardian-macos. Half a day of code; shipping it needs `GUARDIAN_TEAM_ID`, which needs a Developer ID and an approved Endpoint Security entitlement.
4. Task 6 — guardian-macos. One day.
5. Task 7 — guardian-macos. Three to four days, own ADR, own measurement.

## Before the next release

Independently of this plan: state in the release notes that the current build is ad-hoc signed and that a local process can therefore impersonate the app to the system extension. Describe the limitation, not the reproduction.
