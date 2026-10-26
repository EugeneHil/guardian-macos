# Guardian Server Implementation Plan (Plan 3 of 4)

> Formerly Warden.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `guardian-server`: a C++17 HTTPS policy server (agent API + admin API) with a static admin web panel, per-agent tokens, file storage, CI on Windows, and an automated deploy to the Windows VPS, released as `v0.1.0`.

**Architecture:** A static library `guardian_server_lib` of small units behind interfaces: crypto/time utilities → config → storage (`PolicyStore`, `AgentStore`, `EventStore`, file implementations) → services (`PolicyService`) → a socket-free `Api` (`HttpRequest` → `HttpResponse`, all routing/auth/validation) → a thin cpp-httplib adapter (`HttpServer`, TLS) → CLI (`serve`, `token`, `cert`). Policy validation is `guardian::parsePolicy` from guardian-core; the server adds publish/versioning only. The panel is static HTML/CSS/vanilla JS using generated `tokens.css`.

**Tech Stack:** C++17, CMake ≥ 3.25 + presets, Ninja, cpp-httplib (pinned tag) + OpenSSL 3 (vcpkg manifest on Windows, Homebrew/system elsewhere), nlohmann/json `v3.12.0` and GoogleTest `v1.17.0` (same pins as guardian-core), `guardian-core` git submodule at `v0.1.0`, GitHub Actions, PowerShell + NSSM on the VPS, Python 3 stdlib scripts (3.9-compatible).

**Spec:** `docs/superpowers/specs/2026-10-20-guardian-design.md` (§4.5 server, §3 constraints, §6 secrets, §7 quality, §8 VPS and deployment, §9 acceptance steps 1–2). Prior art: Plan 2 (`2026-10-21-guardian-02-core.md`, public API contract), ADR-0001 of guardian-macos, `HANDOFF.md`.

**Where the work happens:** all tasks run in `/Users/eugene/Mine/git/guardian/guardian-server` (Claude Code started there so its guard hook is active). Paths are relative to that repo. Work lands in five PRs to `develop`: A = Tasks 1–2, B = Tasks 3–8, C = Tasks 9–13, D = Task 14, E = Tasks 15–16; Task 17 is the release. **Ask the owner (AskUserQuestion) before every merge, before applying rulesets, before anything that touches the VPS or GitHub Secrets, and before pushing the tag.** Squash merges only; `gh pr update-branch <n>` when behind. Commit trailer and PR footer as in `HANDOFF.md`. Branches: A `feature/WRD-10-server-scaffold`, B `feature/WRD-11-server-core-services`, C `feature/WRD-12-server-http`, D `feature/WRD-13-admin-panel`, E `feature/WRD-14-server-deploy`.

## Global Constraints

- C++17 only; no WinAPI and no platform-specific headers in `src/` (portable `<filesystem>`, `<chrono>`, OpenSSL); builds on Windows (official, CI), macOS (local dev + quality job) and Linux (**unofficial dev build**, not in CI).
- Flags `-Wall -Wextra -Wpedantic -Werror` (MSVC `/W4 /WX`) on our targets only; third-party code is `SYSTEM`. clang-format and clang-tidy are gates. Handler/service line coverage ≥ 80 % (llvm-cov, macOS job) is a gate.
- Dependencies are exactly: guardian-core (submodule, tag `v0.1.0`), cpp-httplib, OpenSSL, nlohmann/json `v3.12.0`, GoogleTest `v1.17.0`; NSSM is a VPS tool. Anything else needs an ADR in `docs/adr/`.
- Policy semantics are guardian-core's (blocklist, default allow). The server never evaluates requests; it validates with `guardian::parsePolicy` and **refuses to publish an invalid policy**.
- Endpoints, auth and storage exactly as spec §4.5: agent `Authorization: Bearer <token>`, admin HTTP Basic over HTTPS, `ETag: "v<N>"`, `data/policies/vN.json` + active pointer, `data/agents.json` (hashed tokens), `data/events.jsonl` with rotation, `agentId` derived from the token (never from the payload).
- Secrets: TLS cert/key paths and admin password come from environment variables or `config.local.json` (gitignored); only `config.example.json` is committed. No secret, token, password or `Authorization` value is ever logged, echoed (except `token add` printing the new token once on stdout) or committed. Tests generate keys in memory or in temp dirs at run time.
- Fail-closed on auth and config: refuse to start with an admin password shorter than 12 characters or without TLS (plain HTTP only with `allowInsecureHttp` on a loopback host). Every non-agent route, including the static panel, requires admin auth. The anti-goal "admin panel reachable without authentication" is a release blocker.
- JSON error body everywhere: `{"error":"<code>","message":"<text>"}`; no exception text, path or stack trace reaches a client. Request body limit 1 MiB (413).
- TDD: failing test first, watch it fail, then implement. Never commit to `main`/`develop`; Conventional Commits; never `--no-verify`. Repository text in English.

## Contract with the agent (consumed by Plan 4)

Base URL `https://<host>:8443`. TLS certificate is self-signed (ECDSA P-256, SAN = the host); the agent pins `base64(SHA-256(DER SubjectPublicKeyInfo))` printed by `guardian-server cert generate` / `cert pin` (same format as `curl --pinnedpubkey sha256//<pin>`).

| Request | Response |
|---|---|
| `GET /api/v1/policy`, `Authorization: Bearer wdn_<64 hex>`, optional `If-None-Match: "v3"` (also accepts `W/"v3"`, lists, `*`) | `200` body = the exact stored `vN.json` (its `"version"` equals N), `ETag: "v3"`, `Content-Type: application/json`; or `304` with `ETag` and no body when the active version matches |
| `POST /api/v1/events`, Bearer, body = JSON array (1–500 items) of `{"ts":"2026-10-21T08:30:00Z","process":{"path","signingId","teamId"},"responsible":{…}\|null,"file","decision":"deny"\|"allow","ruleId"}` (`signingId`/`teamId`/`ruleId`/`responsible` optional; strings ≤ 4096 bytes; unknown keys ignored) | `200 {"accepted":n}`; whole batch rejected with `400 {"error":"invalid_events","errors":[{"path":"[2].file","message":"…"}]}` if any item is invalid |
| `GET /healthz` (no auth) | `200 {"status":"ok","version":"0.1.0"}` |
| `401` (+ `WWW-Authenticate`), `429` (+ `Retry-After`) | bad/missing credentials; throttled after 5 consecutive failures per remote address, 60 s |

A fresh server bootstraps an empty policy as **v1** (`{"schemaVersion":1,"version":1,"rules":[]}`), so the first publish is **v2** (matches spec §9). Drafts carry `"version": 0`; publish rewrites `version` to N+1. Admin API (JSON; Basic `admin:<password>`): `GET /api/v1/admin/policy` → `{"active":{"version":N,"policy":{…}},"draft":null|{"text":"…","validation":{"valid":bool,"errors":[{"path","message"}]}}}`; `PUT /api/v1/admin/policy/draft` (body = raw policy text, saved even if invalid) → `200 {"valid":bool,"errors":[…]}`; `POST /api/v1/admin/policy/publish` → `200 {"version":N+1}` (draft cleared), `409 no_draft`, `422 invalid_draft` + `errors`; `GET /api/v1/admin/events?limit=` (default 100, 1–1000, newest first) → `{"events":[{…event…,"agentId","receivedAt"}]}`; `GET /` and `/app.js`, `/panel.css`, `/tokens.css` → static panel files (allowlist, never a filesystem path from the URL).

## Review Focus

1. Credential confusion and garbage auth: an agent token on an admin route, admin Basic on an agent route, empty/oversized/malformed `Authorization` (`Bearer `, `Basic !!!`, 10 KB value), wrong scheme case, and a revoked token all give `401`, never `500` or access. *(Task 9 parsers; Tasks 10–11 `…RejectsOtherCredentialKind`, `GarbageAuthorizationIs401`)*
2. Publish integrity: invalid or garbage drafts never become active; a draft claiming `"version": 99` is published as N+1; concurrent publishes yield consecutive versions; a crash between writing `vN.json` and flipping the pointer leaves the old version active. *(Tasks 6–7 `CrashBeforePointerFlipKeepsOldVersion`, `ForcesVersionToNextNumber`, `ConcurrentPublishesAreConsecutive`)*
3. Corrupt or hostile on-disk state: a truncated `agents.json` authenticates nobody (never everybody) and a corrupt active pointer or missing `vN.json` stops startup with a clear error; a torn last line in `events.jsonl` is skipped on read. *(Tasks 5, 6, 8 `CorruptAgentsFileAuthenticatesNobody`, `CorruptPointerFailsFast`, `TornLastLineIsSkipped`)*
4. Event-ingestion abuse: 10 000-item batch, 1 MiB+ body, 100 000-deep nesting, invalid UTF-8, control characters and `<script>` in file names (stored verbatim, escaped by the panel), oversize strings, `decision` outside `deny|allow`. *(Task 8 `parseEventBatch` tests; Task 10 `OversizeBodyIs413`; Task 14 static panel check)*
5. Static serving and exposure: `/../config.local.json`, `/%2e%2e/`, `//etc/passwd`, `/data/agents.json` never serve files; `/healthz` reveals only the version; brute-force against Basic auth is throttled; the server will not start with a weak password or plain HTTP on a public interface. *(Task 4 config tests; Task 9 `AuthThrottle`; Task 11 `StaticServesOnlyAllowlist`, `TraversalAttemptsAre404`)*

Known and documented limitations: events are not de-duplicated server-side (agent retries may duplicate); one shared admin account; `data/` ACLs are set by the install script, not by the server; no TLS client-certificate auth.

---

### Task 1: Scaffold, submodule, dependencies ADR, smoke test

**Files:**
- Create: `CMakeLists.txt`, `CMakePresets.json`, `vcpkg.json`, `cmake/Dependencies.cmake`, `cmake/Warnings.cmake`
- Create: `src/version.hpp`, `src/version.cpp`, `tests/smoke_test.cpp`, `docs/adr/0001-server-dependencies.md`
- Create: `external/guardian-core` (git submodule at tag `v0.1.0`)
- Modify: `.gitignore` (verify `build/`, `data/`, `config.local.json`, `vcpkg_installed/` are covered)

**Interfaces:**
- Produces: targets `guardian_server_lib` (static; sources listed explicitly in the CMake file, private include dir `src/`, links `guardian::core`, `nlohmann_json::nlohmann_json`, `httplib::httplib`, `OpenSSL::SSL OpenSSL::Crypto`, private `guardian_warnings`), executable `guardian-server` (`src/main.cpp`), and `guardian_tests` (GoogleTest, `tests/*_test.cpp` via `file(GLOB … CONFIGURE_DEPENDS)`, `gtest_discover_tests`, timeout 20). `std::string_view guardian::server::serverVersion() noexcept` returns `PROJECT_VERSION` (`0.1.0`) via compile definition `GUARDIAN_SERVER_VERSION`. Namespace for all server code: `guardian::server`.
- `Dependencies.cmake` declares nlohmann/json and googletest **before** `add_subdirectory(external/guardian-core)` with exactly guardian-core's tags and options (`JSON_BuildTests OFF`, `INSTALL_GTEST OFF`, `gtest_force_shared_crt ON`) so guardian-core's own declarations are ignored; httplib via FetchContent at the pinned tag with `HTTPLIB_REQUIRE_OPENSSL ON`, `HTTPLIB_COMPILE OFF`, `SYSTEM`. OpenSSL via `find_package(OpenSSL 3 REQUIRED)`.
- Presets (Ninja, binary dir `build/<name>`; configure+build+test): `windows` (condition host Windows, `cl`, toolchain `$env{VCPKG_INSTALLATION_ROOT}/scripts/buildsystems/vcpkg.cmake`, `VCPKG_TARGET_TRIPLET=x64-windows-static-md`), `macos` (`OPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3`), `linux` (unofficial), `coverage` (macOS clang with `-fprofile-instr-generate -fcoverage-mapping`, as in guardian-core). `vcpkg.json` lists `openssl` with a `builtin-baseline` commit (obtain with `vcpkg x-update-baseline --add-initial-baseline`, or the latest vcpkg `master` commit via `git ls-remote https://github.com/microsoft/vcpkg HEAD`).

- [ ] **Step 1: Branch and submodule** — `git switch develop && git pull --ff-only && git switch -c feature/WRD-10-server-scaffold`; `git submodule add https://github.com/EugeneHil/guardian-core.git external/guardian-core && git -C external/guardian-core checkout v0.1.0`; confirm `git submodule status` prints `v0.1.0`-describable hash.
- [ ] **Step 2: Write the failing test** `tests/smoke_test.cpp`: `TEST(Smoke, VersionIsSemver)` (regex `\d+\.\d+\.\d+`, equals `"0.1.0"`), `TEST(Smoke, LinksGuardianCoreAndRejectsGarbagePolicy)` (`guardian::parsePolicy("not json").ok()` is false and `errors` is non-empty), `TEST(Smoke, LinksNlohmannAndOpenSsl)` (`nlohmann::json::parse("[1]").size() == 1`; `OPENSSL_VERSION_MAJOR >= 3`).
- [ ] **Step 3: Run to verify it fails** — `cmake --preset macos && cmake --build --preset macos` → Expected: FAIL (`version.hpp` missing). Write `Warnings.cmake`/`Dependencies.cmake` first (copy the flag set from `external/guardian-core/cmake/Warnings.cmake`) so the failure is the missing header.
- [ ] **Step 4: Implement** `serverVersion()`, the targets and presets; `src/main.cpp` is a stub returning 0 until Task 13. Verify the cpp-httplib tag with `git ls-remote --tags https://github.com/yhirose/cpp-httplib` and pin the newest stable `v0.x.y` tag at least two weeks old.
- [ ] **Step 5: Run to verify it passes** — `cmake --build --preset macos && ctest --preset macos --output-on-failure` → Expected: `100% tests passed, 0 tests failed out of 3`.
- [ ] **Step 6: Write `docs/adr/0001-server-dependencies.md`** (Status/Context/Decision/Consequences, English, ≤ 50 lines): cpp-httplib + OpenSSL (spec §4.5) and why not Boost.Beast/Crow, vcpkg manifest with baseline on Windows and the `x64-windows-static-md` triplet (static libs, dynamic CRT to match GoogleTest's shared CRT; VPS needs the VC++ redistributable), identical nlohmann/googletest pins as guardian-core, bump procedure for the `guardian-core` submodule.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "build: add CMake scaffold, guardian-core submodule and dependency ADR"`.

### Task 2: Quality gates, CI, required checks

**Files:**
- Create: `.clang-format`, `.clang-tidy` (copy from `external/guardian-core`), `scripts/lint.sh`, `scripts/coverage.sh`, `scripts/coverage_gate.py`, `scripts/test_coverage_gate.py`, `.github/workflows/ci.yml`
- Modify: `README.md` (build/test/lint/coverage commands, layout stub)

**Interfaces:**
- Consumes: Task 1 presets and targets. `scripts/*` are adapted copies of guardian-core's (`lint.sh` covers `src tests`; `coverage.sh` exports `guardian_tests` ignoring `_deps`, `external/`, `tests/` and `src/main.cpp`; gate `--min 80`).
- Produces CI jobs named exactly `server-windows` (windows-latest: `actions/checkout` with `submodules: recursive`, `ilammy/msvc-dev-cmd@v1`, preset `windows` build + test), `server-quality` (macos-latest: `brew install ninja llvm openssl@3`, preset `macos` build + test, `scripts/lint.sh`, `scripts/coverage.sh`). Workflow `permissions: contents: read`, triggers `pull_request` and `push` to `develop`/`main`.

- [ ] **Step 1: Write failing gate tests** `scripts/test_coverage_gate.py` (`test_passes_at_or_above_min`, `test_fails_below_min`, `test_rejects_malformed_summary` → exit 2) — run `python3 -I -B -m unittest discover -s scripts` → Expected: FAIL. Implement `coverage_gate.py` (copy of guardian-core's) → PASS.
- [ ] **Step 2: Prove lint fails** on a deliberately bad line in `src/version.cpp`; remove it; `scripts/lint.sh` exits 0 on the clean tree. `scripts/coverage.sh` prints a percentage ≥ 80 and exits 0.
- [ ] **Step 3: Write `ci.yml`** with the two jobs above. Local check: `python3 -c "import yaml"` is not available by default, so validate with `gh workflow` after push instead.
- [ ] **Step 4: Commit** (`build: add lint and coverage gates`, `ci: add Windows and macOS quality jobs`), push, open **PR A** (`gh pr create --base develop --title "build: server scaffold and quality gates"`); fix MSVC/vcpkg issues until `server-windows`, `server-quality`, `gitleaks` are green (`gh pr checks <n> --watch`). **Ask the owner, then squash-merge.**
- [ ] **Step 5: Require the checks (ask the owner first)** — from inside `guardian-server`: `../guardian-core/tooling/github/bootstrap-repo.sh guardian-server "$(gh repo view --json description -q .description)" server-windows server-quality`; verify both appear in both rulesets with `gh api repos/EugeneHil/guardian-server/rulesets`.

### Task 3: Crypto, encoding and time utilities

**Files:**
- Create: `src/crypto.hpp`, `src/crypto.cpp`, `src/timeutil.hpp`, `src/timeutil.cpp`, `src/fs_util.hpp`, `src/fs_util.cpp`
- Test: `tests/crypto_test.cpp`, `tests/timeutil_test.cpp`, `tests/fs_util_test.cpp`
- Modify: `CMakeLists.txt` (add sources)

**Interfaces:**
- Produces (`namespace guardian::server`; failures throw `class CryptoError : public std::runtime_error`):
  - `std::string sha256Hex(std::string_view data);`
  - `std::string randomToken();` → `"wdn_"` + 64 lowercase hex (32 bytes from `RAND_bytes`)
  - `bool constantTimeEquals(std::string_view a, std::string_view b) noexcept;` (false on length mismatch, otherwise `CRYPTO_memcmp`)
  - `std::string base64Encode(std::string_view bytes);` `std::optional<std::string> base64Decode(std::string_view text);` (standard alphabet with padding; nullopt on any invalid input)
  - `struct CertPair { std::string certPem; std::string keyPem; };` `CertPair generateSelfSignedCert(std::string_view host, int validDays);` (ECDSA P-256 via `EVP_EC_gen("P-256")`, subject `CN=<host>`, SAN = IP if `host` parses as IPv4/IPv6 else DNS, SHA-256 signature, random serial)
  - `std::string spkiPin(std::string_view certPem);` = `base64Encode(SHA-256(DER SubjectPublicKeyInfo))`
  - `using TimePoint = std::chrono::system_clock::time_point; using NowFn = std::function<TimePoint()>;` `std::string formatUtc(TimePoint);` → `"2026-10-21T08:30:00Z"`; `std::optional<TimePoint> parseUtc(std::string_view);` accepts `YYYY-MM-DDTHH:MM:SS` with optional `.fraction` and mandatory `Z`, rejects impossible dates (Feb 30) — implement with a days-from-civil algorithm, not `gmtime` (MSVC warns).
  - `void writeFileAtomic(const std::filesystem::path&, std::string_view content, bool ownerOnly = false);` (temp file in the same dir + `std::filesystem::rename`; creates parent dirs; `ownerOnly` sets 0600 permissions; throws `StorageError`) and `std::optional<std::string> readFile(const std::filesystem::path&);`. `class StorageError : public std::runtime_error` is declared in `fs_util.hpp`.

- [ ] **Step 1: Write the failing tests**: `Sha256Hex.KnownVector` (`"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`; empty string → `e3b0c442…b855`), `RandomToken.FormatAndUniqueness` (regex `^wdn_[0-9a-f]{64}$`, 1000 tokens distinct), `ConstantTimeEquals.Cases`, `Base64.RoundTripAndRfc4648Vectors` (`"foobar"` ↔ `Zm9vYmFy`, `"fo"` ↔ `Zm8=`; `base64Decode("Zm9v!")` and `"Zm9"` are nullopt), `SelfSignedCert.PinIsStable44CharBase64AndDiffersPerCert`, `SelfSignedCert.SanContainsIpOrDns` (parse with OpenSSL in the test and check the SAN type for `"203.0.113.7"` vs `"guardian.example"`), `Spki.RejectsGarbagePem` (throws `CryptoError`); `FormatUtc.EpochAndLeapDay` (`0` → `1970-01-01T00:00:00Z`, `2024-02-29T23:59:59Z` round-trips), `ParseUtc.RejectsBadInput` (`2026-02-30T00:00:00Z`, missing `Z`, `2026-10-21 08:30:00Z`, empty, 1 MiB string), `ParseUtc.AcceptsFraction`; `WriteFileAtomic.ReplacesContentAndLeavesNoTempFile`, `WriteFileAtomic.CreatesParentDirs`, `ReadFile.MissingIsNullopt`.
- [ ] **Step 2: Run to verify they fail** (`ctest --preset macos`) → Expected: build FAIL (headers missing).
- [ ] **Step 3: Implement** the functions above in the named files; RAII wrappers (`std::unique_ptr` with OpenSSL deleters) for `EVP_PKEY`, `X509`, `BIO`.
- [ ] **Step 4: Verify** all tests green and `scripts/lint.sh` clean. Manual cross-check once (not committed): `openssl x509 -in <cert from a test run> -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64` equals `spkiPin` of the same cert.
- [ ] **Step 5: Commit** — `git switch -c feature/WRD-11-server-core-services` (before the first commit of PR B) then `git commit -m "feat: add crypto, time and atomic file utilities"`.

### Task 4: Configuration

**Files:**
- Create: `src/config.hpp`, `src/config.cpp`, `config.example.json`
- Test: `tests/config_test.cpp`

**Interfaces:**
- Consumes: nothing from earlier tasks except nlohmann/json.
- Produces:
```cpp
struct TlsConfig { std::string certPath, keyPath; };
struct Config { std::string host = "0.0.0.0"; int port = 8443; std::optional<TlsConfig> tls;
                bool allowInsecureHttp = false; std::string dataDir = "data"; std::string webRoot = "web";
                std::string adminPassword; };
struct ConfigResult { std::optional<Config> config; std::vector<std::string> errors; };  // config has value iff errors empty
using EnvLookup = std::function<std::optional<std::string>(std::string_view)>;
ConfigResult loadConfig(std::string_view fileJson, const EnvLookup& env);   // fileJson may be empty (no file)
```
  JSON keys: `host`, `port`, `tls{certPath,keyPath}`, `allowInsecureHttp`, `dataDir`, `webRoot`, `adminPassword`. Env overrides (win over file): `GUARDIAN_HOST`, `GUARDIAN_PORT`, `GUARDIAN_TLS_CERT`, `GUARDIAN_TLS_KEY`, `GUARDIAN_DATA_DIR`, `GUARDIAN_WEB_ROOT`, `GUARDIAN_ADMIN_PASSWORD`. Exact error strings: `adminPassword: must be at least 12 characters`; `tls: certPath and keyPath are required (or set allowInsecureHttp on a loopback host)`; `allowInsecureHttp: only allowed with host 127.0.0.1, ::1 or localhost`; `port: must be between 1 and 65535`; `$: invalid JSON`; `<key>: unknown key` for unknown keys; `<key>: wrong type`. `config.example.json` holds placeholders only, with `"adminPassword": ""` (so it fails validation as-is) and a `_comment` key; `loadConfig` ignores keys that start with `_`.

- [ ] **Step 1: Write the failing tests**: `AcceptsMinimalValidConfig`, `EnvOverridesFile`, `RejectsShortOrEmptyPassword` (11 chars, empty, missing), `RequiresTlsUnlessLoopbackInsecure`, `InsecureHttpOnPublicHostIsRejected` (`0.0.0.0`, `203.0.113.7`), `InsecureHttpOnLoopbackIsAccepted`, `RejectsBadPorts` (0, 65536, `"8443"` as string, env `GUARDIAN_PORT=abc`), `RejectsUnknownKeysAndWrongTypes`, `GarbageJsonIsAnError` (empty object is fine, `[]`, `{`, invalid UTF-8), `ReportsAllErrorsTogether`, `ExampleConfigParsesButIsNotValid` (reads `config.example.json` and expects the password error, proving placeholders cannot run as-is).
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL (undefined `loadConfig`).
- [ ] **Step 3: Implement** `loadConfig` (no exceptions escape; catch `nlohmann::json::exception`).
- [ ] **Step 4: Run to verify they pass** and lint is clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add configuration loading with fail-closed validation"`.

### Task 5: Agent store and tokens

**Files:**
- Create: `src/agent_store.hpp`, `src/agent_store.cpp`
- Test: `tests/agent_store_test.cpp`

**Interfaces:**
- Consumes: `sha256Hex`, `randomToken`, `constantTimeEquals`, `formatUtc`, `NowFn`, `writeFileAtomic`, `readFile`, `StorageError` (Task 3).
- Produces:
```cpp
bool isValidAgentId(std::string_view id) noexcept;               // [A-Za-z0-9._-]{1,64}
struct AgentInfo { std::string id; std::string createdAt; };
class AgentStore { public: virtual ~AgentStore() = default;
  virtual std::optional<std::string> add(std::string_view agentId) = 0;  // new token; nullopt if id exists; throws StorageError on I/O, std::invalid_argument on invalid id
  virtual bool remove(std::string_view agentId) = 0;
  virtual std::vector<AgentInfo> list() const = 0;
  virtual std::optional<std::string> authenticate(std::string_view token) const = 0; };  // agentId or nullopt
class FileAgentStore final : public AgentStore { public: FileAgentStore(std::filesystem::path dataDir, NowFn now); … };
```
  File `data/agents.json` = `{"agents":[{"id","tokenHash","createdAt"}]}`, written atomically with `ownerOnly=true`; `authenticate` **re-reads the file on every call** (so CLI changes apply live) and compares the SHA-256 of the presented token against every entry with `constantTimeEquals`. Missing file = no agents. Unreadable/corrupt file = no agent authenticates (and `list()` throws `StorageError`).

- [ ] **Step 1: Write the failing tests**: `AddReturnsTokenThatAuthenticates`, `TokenIsStoredHashedOnly` (read the raw file: it contains neither the token nor `wdn_`), `DuplicateIdReturnsNullopt`, `InvalidIdThrows` (empty, 65 chars, `../x`, space, NUL), `RemoveRevokesImmediately`, `AuthenticateRejectsGarbage` (empty, 1 MiB token, wrong prefix, a prefix of a valid token, a valid token with an extra char), `CorruptAgentsFileAuthenticatesNobody` (truncated JSON, `[]`, `{"agents":"x"}`; `list()` throws), `SecondInstanceSeesChangesFromFirst` (CLI scenario), `ListIsSortedById`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** `FileAgentStore`; serialise writers with a `std::mutex`.
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add per-agent token store"`.

### Task 6: Policy store

**Files:**
- Create: `src/policy_store.hpp`, `src/file_policy_store.cpp`
- Test: `tests/policy_store_test.cpp`

**Interfaces:**
- Consumes: `writeFileAtomic`, `readFile`, `StorageError`; `guardian::parsePolicy` (to validate the bootstrap document in a test).
- Produces:
```cpp
struct PolicyDoc { std::int64_t version = 0; std::string json; };
class PolicyStore { public: virtual ~PolicyStore() = default;
  virtual PolicyDoc active() const = 0;                       // never empty
  virtual std::optional<std::string> draft() const = 0;
  virtual void saveDraft(std::string_view text) = 0;
  virtual void clearDraft() = 0;
  virtual void commit(const PolicyDoc& doc) = 0; };           // doc.version must be active().version + 1, else StorageError
class FilePolicyStore final : public PolicyStore { public: explicit FilePolicyStore(std::filesystem::path dataDir); … };
```
  Layout: `data/policies/v<N>.json`, `data/policies/active` (decimal N + `\n`), `data/policies/draft.json`. Constructor bootstraps v1 = `{"schemaVersion":1,"version":1,"rules":[]}` when the directory has no active pointer; throws `StorageError` if the pointer is not a positive integer or `v<N>.json` is missing/unreadable. `commit` writes `v<N>.json` first, then flips the pointer (both atomic). All methods are internally synchronised.

- [ ] **Step 1: Write the failing tests**: `BootstrapsEmptyPolicyV1` (and `parsePolicy(active().json).ok()`), `ReopeningKeepsActive`, `CommitMakesNextVersionActive`, `CommitRejectsNonConsecutiveVersions` (same version, +2, 0), `CrashBeforePointerFlipKeepsOldVersion` (create `v2.json` by hand without moving the pointer, reopen: active is still v1, and a later `commit` of v2 succeeds and overwrites), `DraftSaveReadClear`, `DraftKeepsInvalidTextVerbatim`, `CorruptPointerFailsFast` (`""`, `abc`, `-1`, `0`, `2` with no `v2.json`), `ConcurrentCommitsNeverCorrupt` (8 threads racing for v2: exactly one succeeds, others throw, file valid).
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** `FilePolicyStore`.
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add file-backed policy store"`.

### Task 7: Policy service (draft validation and publish)

**Files:**
- Create: `src/policy_service.hpp`, `src/policy_service.cpp`
- Test: `tests/policy_service_test.cpp`

**Interfaces:**
- Consumes: `PolicyStore`/`PolicyDoc` (Task 6), `guardian::parsePolicy`, `guardian::ValidationError` (guardian-core).
- Produces:
```cpp
struct ValidationReport { bool valid = false; std::vector<guardian::ValidationError> errors; };
struct PublishResult { enum class Failure { None, NoDraft, Invalid } failure = Failure::None;
                       std::optional<PolicyDoc> published; std::vector<guardian::ValidationError> errors; };
class PolicyService { public: explicit PolicyService(PolicyStore& store);
  PolicyDoc active() const;
  std::optional<std::string> draft() const;
  ValidationReport saveDraft(std::string_view text);   // saves verbatim even if invalid; text > 1 MiB is not saved: {valid=false, errors=[{"$","policy larger than 1 MiB"}]}
  ValidationReport validateDraft() const;               // no draft → valid=false, errors=[{"$","no draft"}]
  PublishResult publish(); };
```
  `publish`: under one mutex, parse the draft; on errors return `Invalid` (nothing written); otherwise parse the text with nlohmann, set `version = active().version + 1`, `dump(2)` + `\n`, re-validate the result with `parsePolicy` and require `policy->version == N+1` (else throw `StorageError`), `store.commit`, `store.clearDraft`, return the new `PolicyDoc`.

- [ ] **Step 1: Write the failing tests** (use `FilePolicyStore` on a temp dir): `SaveDraftReportsAllErrorsWithJsonPaths` (reuses the spec's `rules[0].processes[2]: empty matcher` through `describe()`), `SaveDraftKeepsInvalidTextAndGarbage`, `OversizeDraftIsRejected`, `PublishInvalidDraftChangesNothing`, `PublishWithoutDraftIsNoDraft`, `ForcesVersionToNextNumber` (draft says `"version": 99` or omits it → published `version == 2` and `json` contains `"version": 2`), `PublishClearsDraftAndServesNewActive`, `SecondPublishIsV3`, `PublishedJsonRoundTripsThroughParsePolicy`, `ConcurrentPublishesAreConsecutive` (two threads each save+publish: versions are {2,3} or the loser gets `NoDraft`, never a duplicate), `DuplicateJsonKeysInDraftAreRejected`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** `PolicyService`.
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add policy draft validation and publish"`.

### Task 8: Events (parsing, storage, rotation)

**Files:**
- Create: `src/event.hpp`, `src/event.cpp`, `src/event_store.hpp`, `src/file_event_store.cpp`
- Test: `tests/event_test.cpp`, `tests/event_store_test.cpp`

**Interfaces:**
- Consumes: `NowFn`, `formatUtc`, `parseUtc`, `StorageError` (Task 3); `guardian::ValidationError`.
- Produces:
```cpp
struct ProcessRef { std::string path, signingId, teamId; };
struct Event { std::string ts; ProcessRef process; std::optional<ProcessRef> responsible;
               std::string file, decision, ruleId; };
struct StoredEvent { Event event; std::string agentId; std::string receivedAt; };
struct EventBatchResult { std::vector<Event> events; std::vector<guardian::ValidationError> errors; };  // events valid iff errors empty
constexpr std::size_t kMaxEventsPerBatch = 500, kMaxEventStringBytes = 4096;
EventBatchResult parseEventBatch(std::string_view json);
nlohmann::json toJson(const StoredEvent&);          // keys exactly as in the contract plus agentId, receivedAt
class EventStore { public: virtual ~EventStore() = default;
  virtual void append(std::string_view agentId, const std::vector<Event>& events) = 0;
  virtual std::vector<StoredEvent> recent(std::size_t limit) const = 0; };   // newest first
class FileEventStore final : public EventStore { public:
  FileEventStore(std::filesystem::path dataDir, NowFn now,
                 std::uintmax_t maxFileBytes = 5 * 1024 * 1024, int keepFiles = 5); … };
```
  Validation error paths: `$` (not an array / empty / more than 500 items / invalid JSON), `[i].ts`, `[i].process.path`, `[i].file`, `[i].decision`, with messages `required string`, `must be an ISO-8601 UTC timestamp`, `must be "deny" or "allow"`, `longer than 4096 bytes`; invalid UTF-8 anywhere is an error. Storage: one JSON object per line in `data/events.jsonl`; when the file would exceed `maxFileBytes` it rotates to `events.1.jsonl`…`events.<keepFiles-1>.jsonl` (oldest deleted). `recent` reads newest file first across rotations and skips lines that fail to parse.

- [ ] **Step 1: Write the failing tests** `event_test.cpp`: `AcceptsMinimalAndFullEvent`, `IgnoresUnknownKeys`, `RejectsNonArrayEmptyAndTooLarge` (`{}`, `[]`, 501 items, 10 000 items), `ReportsAllItemErrorsWithPaths` (`[2].file`), `RejectsBadDecision`, `RejectsBadTimestamp`, `RejectsOversizeStrings`, `RejectsInvalidUtf8`, `DeepNestingDoesNotCrash` (100 000 `[`), `ControlCharsAndHtmlAreKeptVerbatim` (`<script>` and `\u0000` in `file` round-trip through `toJson`). `event_store_test.cpp`: `AppendThenRecentNewestFirst`, `RecordsAgentIdAndReceivedAt`, `LimitIsHonoured`, `RotatesAndKeepsAtMostKeepFiles`, `RecentSpansRotatedFiles`, `TornLastLineIsSkipped` (append a half line by hand), `EmptyStoreIsEmpty`, `ConcurrentAppendsDoNotInterleaveLines`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** parsing (nlohmann `parse` with exceptions disabled via the callback overload / `accept` pre-check, depth guard: reject nesting > 64 before parsing) and the file store.
- [ ] **Step 4: Run to verify they pass**; `ctest --preset macos`, `scripts/lint.sh`, `scripts/coverage.sh` all green.
- [ ] **Step 5: Commit** (`feat: add event batch validation and rotating event store`), push, open **PR B** (`feat: server storage and policy publishing`); wait for the three checks green. **Ask the owner, then squash-merge**; update local `develop`.

### Task 9: Auth helpers and throttle

**Files:**
- Create: `src/auth.hpp`, `src/auth.cpp`
- Test: `tests/auth_test.cpp`
- Branch: `git switch -c feature/WRD-12-server-http` from updated `develop`.

**Interfaces:**
- Consumes: `base64Decode`, `constantTimeEquals`, `NowFn` (Task 3).
- Produces:
```cpp
std::optional<std::string> parseBearer(std::string_view authorizationHeader);       // scheme is case-insensitive; token non-empty, ≤ 256 bytes, no whitespace
struct BasicCredentials { std::string user, password; };
std::optional<BasicCredentials> parseBasic(std::string_view authorizationHeader);   // header ≤ 1024 bytes; split at the FIRST ':'
bool adminCredentialsMatch(const BasicCredentials&, std::string_view expectedPassword) noexcept;  // user must be "admin"; both comparisons run, constant time
class AuthThrottle { public: explicit AuthThrottle(NowFn now, int maxFailures = 5, std::chrono::seconds lockout = std::chrono::seconds(60));
  bool blocked(const std::string& key);                 // true while ≥ maxFailures consecutive failures and lockout not elapsed since the last
  std::chrono::seconds retryAfter(const std::string& key);
  void recordFailure(const std::string& key);
  void recordSuccess(const std::string& key); };        // thread-safe; at most 10 000 keys tracked (oldest evicted)
```

- [ ] **Step 1: Write the failing tests**: `Bearer.AcceptsValidAndCaseInsensitiveScheme`, `Bearer.RejectsEmptyWhitespaceOversizeAndWrongScheme` (`Bearer `, `Bearer a b`, `Basic x`, 10 KB token, empty header), `Basic.ParsesUserAndPasswordWithColonInPassword`, `Basic.RejectsBadBase64AndMissingColon` (`Basic !!!`, `Basic Zm9v` = "foo"), `Basic.RejectsOversizeHeader`, `AdminMatch.RequiresUserAdmin`, `AdminMatch.WrongOrEmptyPasswordFails`, `Throttle.BlocksAfterFiveFailuresForSixtySeconds` (fake clock), `Throttle.SuccessResetsCounter`, `Throttle.KeysAreIndependent`, `Throttle.UnblocksAfterLockout`, `Throttle.RetryAfterCountsDown`, `Throttle.BoundsMemory` (20 000 keys then still works).
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add HTTP auth parsing and brute-force throttle"`.

### Task 10: API — agent endpoints and health

**Files:**
- Create: `src/api.hpp`, `src/api.cpp`, `src/agent_routes.cpp`
- Test: `tests/api_agent_test.cpp`, `tests/api_test_support.hpp` (fixture creating temp dir, stores, fake clock, `Api`)

**Interfaces:**
- Consumes: `PolicyService`, `AgentStore`, `EventStore`, `parseEventBatch`, `toJson`, `AuthThrottle`, `parseBearer`, `serverVersion`.
- Produces:
```cpp
struct HttpRequest { std::string method, path; std::map<std::string, std::string> headers;  // lower-case names
                     std::map<std::string, std::string> query; std::string body, remoteAddr; };
struct HttpResponse { int status = 200; std::map<std::string, std::string> headers; std::string body; };
struct ApiDeps { PolicyService& policies; AgentStore& agents; EventStore& events; AuthThrottle& throttle;
                 std::string adminPassword; std::filesystem::path webRoot; };
class Api { public: explicit Api(ApiDeps deps); HttpResponse handle(const HttpRequest&) const noexcept; };  // never throws
constexpr std::size_t kMaxBodyBytes = 1024 * 1024;
```
  `handle` returns the JSON error body from Global Constraints for: unknown path `404 not_found`, wrong method on a known path `405 method_not_allowed` (+`Allow`), body over limit `413 payload_too_large`, any exception `500 {"error":"internal"}` (storage errors `500 storage`) without detail. Every response carries `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`; JSON responses `Content-Type: application/json; charset=utf-8`. Routes in this task: `GET /healthz`, `GET /api/v1/policy`, `POST /api/v1/events` exactly per the contract table. Throttle key = `remoteAddr`; a `429` response carries `Retry-After`; successful auth calls `recordSuccess`.

- [ ] **Step 1: Write the failing tests**: `Healthz.NoAuthOnlyVersion`; `Policy.RequiresBearer401WithChallenge`, `Policy.ReturnsBootstrapV1WithEtag` (`ETag: "v1"`, body is the stored text), `Policy.EtagMatchGives304` (`"v1"`, `W/"v1"`, `"v0", "v1"`, `*`) and `Policy.StaleOrMalformedEtagGives200` (`"v0"`, `v1`, empty), `Policy.NewVersionAfterPublish` (agent sees `"v2"` and 304 for `"v2"`), `Policy.RejectsRevokedToken`, `Policy.RejectsAdminBasicCredentials`, `GarbageAuthorizationIs401` (table of 8 values including a 10 KB header and NUL bytes), `Throttle.SixthBadTokenIs429WithRetryAfter` and `Throttle.GoodTokenAfterLockoutStillBlockedUntilExpiry`; `Events.AcceptsBatchAndStoresAgentIdFromToken` (payload containing `"agentId":"evil"` is ignored), `Events.InvalidItemRejectsWholeBatch400WithPaths`, `Events.OversizeBodyIs413`, `Events.RequiresBearer`, `Events.WrongMethod405`, `Events.NonJsonBody400`; `Errors.UnknownPath404`, `Errors.StorageFailureIs500WithoutDetail` (a throwing `EventStore` double), `Errors.NoExceptionEscapes`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** routing in `api.cpp` (exact-match table `method+path`) and the agent handlers in `agent_routes.cpp`; ETag comparison parses a comma-separated list of optionally weak quoted tags.
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add agent policy and event endpoints"`.

### Task 11: API — admin endpoints and static panel files

**Files:**
- Create: `src/admin_routes.cpp`, `src/static_files.hpp`, `src/static_files.cpp`
- Modify: `src/api.cpp` (register routes), `CMakeLists.txt`
- Test: `tests/api_admin_test.cpp`, `tests/static_files_test.cpp`

**Interfaces:**
- Consumes: Task 10 `Api`, `HttpRequest/HttpResponse`; Task 9 `parseBasic`, `adminCredentialsMatch`; Task 7 `PolicyService`; Task 8 `EventStore::recent`, `toJson`.
- Produces: routes `GET /api/v1/admin/policy`, `PUT /api/v1/admin/policy/draft`, `POST /api/v1/admin/policy/publish`, `GET /api/v1/admin/events` exactly per the contract (events `limit` outside 1–1000 or non-numeric → `400 bad_request`); `GET /`, `/app.js`, `/panel.css`, `/tokens.css`. `class StaticFiles { explicit StaticFiles(std::filesystem::path root); std::optional<HttpResponse> serve(std::string_view urlPath) const; }` — an in-code allowlist `{"/" → index.html text/html, "/app.js" → text/javascript, "/panel.css" → text/css, "/tokens.css" → text/css}`; `/index.html` is **not** an alias. HTML responses add `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'` and `Referrer-Policy: no-referrer`. All admin and static routes require valid Basic credentials: missing/wrong → `401` with `WWW-Authenticate: Basic realm="Guardian", charset="UTF-8"`, throttled like agent auth.

- [ ] **Step 1: Write the failing tests**: `Admin.AllRoutesRequireBasic` (table over every admin + static route: no header, wrong password, wrong user, agent Bearer token → 401), `Admin.GetPolicyShowsActiveAndNullDraft`, `Admin.PutDraftValidReturnsValidTrue`, `Admin.PutDraftInvalidReturnsErrorsWithPathsAndStillSaves`, `Admin.PutDraftOversizeIs413`, `Admin.PublishValidDraftReturnsNextVersionAndAgentSeesIt` (end-to-end through `Api`: PUT, publish → `{"version":2}`, agent GET gives `"v2"`), `Admin.PublishInvalidIs422WithErrors`, `Admin.PublishWithoutDraftIs409`, `Admin.EventsNewestFirstAndLimit`, `Admin.EventsBadLimitIs400`, `Admin.SixthBadPasswordIs429`, `Admin.GetOnPublishIs405`; `Static.ServesOnlyAllowlist` (index, app.js, panel.css, tokens.css return file bytes with right types; `/index.html`, `/data/agents.json`, `/config.local.json`, `/web/app.js` are 404), `Static.TraversalAttemptsAre404` (`/../x`, `/%2e%2e/x`, `//etc/passwd`, `/app.js/../../x`, `/app.js%00`, backslash variants), `Static.HtmlHasSecurityHeaders`, `Static.MissingFileOnDiskIs404`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** the routes and `StaticFiles` (read the file per request; no directory listing; no path derived from the URL).
- [ ] **Step 4: Run to verify they pass**, lint clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add admin API and static panel serving"`.

### Task 12: HTTP(S) server adapter

**Files:**
- Create: `src/http_server.hpp`, `src/http_server.cpp`
- Test: `tests/http_server_test.cpp`

**Interfaces:**
- Consumes: `Api`, `TlsConfig`, `generateSelfSignedCert`, `spkiPin`, `writeFileAtomic`.
- Produces:
```cpp
struct ServerOptions { std::string host = "127.0.0.1"; int port = 8443;            // port 0 = pick a free port
                       std::optional<TlsConfig> tls;                               // none = plain HTTP (loopback only, enforced by Config)
                       std::function<void(const std::string&)> accessLog; };      // one line per request
class HttpServer { public: HttpServer(const Api& api, ServerOptions options);
  bool start();            // binds and serves on a background thread; false on bind/TLS-load failure
  int port() const;        // bound port after start()
  void run();              // blocking variant for the CLI (returns when stop() is called or on failure)
  void stop(); ~HttpServer(); };
```
  The adapter copies method, path, lower-cased headers, query params, body and `remote_addr` into `HttpRequest`, writes the `HttpResponse` back, sets 1 MiB payload limit, 10 s read/write timeouts, and logs `"<remote> <method> <path> <status>"` — never headers, query strings or bodies. TLS: min version TLS 1.2 (via `SSL_CTX` from the server object), cert/key loaded from the configured paths.

- [ ] **Step 1: Write the failing tests** (client = `httplib::SSLClient`/`Client` on loopback, certificate verification off *in tests only*, cert/key written by the test to a temp dir with `generateSelfSignedCert`): `ServesHealthzOverTls`, `ServedCertificateMatchesSpkiPin` (fetch peer cert via `SSL_get_peer_certificate` on the client, compare `spkiPin`), `PlainHttpModeWorksOnLoopback`, `PlainHttpRequestToTlsPortFailsHandshake`, `FailsToStartWithMissingCertFile` (`start()` false, no crash), `PolicyEndpointEndToEndWithRealToken`, `AccessLogHasNoSecrets` (send Bearer token and Basic password, query `?limit=5`: captured lines contain neither, nor `Authorization`, nor `limit`), `OversizeBodyRejected`, `StopIsIdempotentAndFreesPort`, `Tls10IsRefused` (client forced to TLS 1.0/1.1 fails if the local OpenSSL permits constructing it; otherwise `GTEST_SKIP` with message).
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** `HttpServer` on `httplib::Server`/`httplib::SSLServer(cert_path, key_path)`; wrap the handler in a try/catch that maps anything to the Task 10 `500 internal` JSON.
- [ ] **Step 4: Run to verify they pass** on macOS; the Windows job must also pass (check after pushing).
- [ ] **Step 5: Commit** — `git commit -m "feat: add HTTPS server adapter"`.

### Task 13: CLI and `main`

**Files:**
- Create: `src/cli.hpp`, `src/cli.cpp`; Modify: `src/main.cpp`
- Test: `tests/cli_test.cpp`

**Interfaces:**
- Consumes: everything above.
- Produces:
```cpp
int runCli(const std::vector<std::string>& args, std::ostream& out, std::ostream& err, const EnvLookup& env, const NowFn& now);
```
  Commands (`args` exclude argv[0]): `version` → `guardian-server 0.1.0`; `help`; `token add <agentId> [--data-dir D]` → prints **only the token** plus newline on `out`, a hint on `err`; `token list` (id + createdAt per line, never hashes), `token remove <agentId>` (exit 1 + message if unknown); `cert generate --host H [--out-dir D] [--days N=825]` → writes `server.crt` and `server.key` (owner-only) into `D` (default `data/tls`), refuses to overwrite existing files, prints `SPKI pin: <base64>` on `out`; `cert pin <certFile>` → prints the pin; `serve [--config PATH]` (default `config.local.json`; a missing file is allowed when env supplies the config) → `loadConfig`, on errors prints each on `err` and exits 1, otherwise builds stores/services/`Api`/`HttpServer` and calls `run()`. Data dir for `token` commands: `--data-dir`, else `GUARDIAN_DATA_DIR`, else `data`. Exit codes 0 ok / 1 runtime error / 2 usage. `serve` and its signal-handling `main` glue are the only untested lines.

- [ ] **Step 1: Write the failing tests**: `Version`, `UnknownCommandIsUsageError2`, `TokenAddPrintsOnlyTokenAndItAuthenticates`, `TokenAddDuplicateExits1`, `TokenAddInvalidIdExits1`, `TokenListNeverPrintsHashesOrTokens`, `TokenRemoveRevokes`, `CertGenerateWritesFilesAndPrintsPin` (pin equals `spkiPin(file)`), `CertGenerateRefusesToOverwrite`, `CertPinOnGarbageFileExits1`, `ServeWithInvalidConfigPrintsAllErrorsAndExits1` (weak password, no TLS) and `ServeErrorsNeverEchoThePassword`.
- [ ] **Step 2: Run to verify they fail** → Expected: FAIL.
- [ ] **Step 3: Implement** `runCli`; `main` converts `argv`, wires `std::getenv` into `EnvLookup`, installs SIGINT/SIGTERM (`<csignal>`) to call `HttpServer::stop` through an atomic flag polled by a watcher thread.
- [ ] **Step 4: Run to verify they pass**; manual smoke on macOS: `build/macos/guardian-server cert generate --host 127.0.0.1 --out-dir <scratch dir>`, then serve with env `GUARDIAN_ADMIN_PASSWORD=<12+ chars>` and `curl --pinnedpubkey sha256//<pin> -u admin:… https://127.0.0.1:8443/api/v1/admin/policy` → 200 (use a scratch dir outside the repo; never commit the files).
- [ ] **Step 5: Commit** (`feat: add CLI for serve, token and cert`), push, open **PR C** (`feat: server HTTP API, TLS and CLI`); wait for `server-windows`, `server-quality`, `gitleaks` green. **Ask the owner, then squash-merge.**

### Task 14: Admin web panel and design tokens

**Files:**
- Create: `web/index.html`, `web/app.js`, `web/panel.css`, `web/tokens.css` (generated), `scripts/tokens.py`, `scripts/test_tokens.py`, `scripts/test_panel_static.py`
- Modify: `.github/workflows/ci.yml` (job `tokens`), `README.md`
- Branch: `feature/WRD-13-admin-panel` from updated `develop`.

**Interfaces:**
- Consumes: Task 11 admin API and static allowlist; `external/guardian-core/design-tokens/generate.py`.
- Produces: `python3 -I -B scripts/tokens.py [--check]` — runs guardian-core's `generate.py --css web/tokens.css --swift <temp dir>/Tokens.swift` (the Swift output goes to a temp dir so the submodule stays clean; guardian-core v0.1.0 has no `--no-swift`); with `--check` it generates into a temp dir and exits 1 if `web/tokens.css` differs. Panel (no build step, no external requests, no frameworks): header "Guardian" with tabs **Policy** and **Events**; Policy tab — badge "Active v N", rules table (id, description, #targets, #processes, action) from the active policy, a monospace draft editor pre-filled from the draft or the active JSON with `"version": 0`, **Save draft** (PUT; shows `valid` or the error list `path: message`), **Publish v N+1** enabled only when the last save returned `valid: true` and the editor is unchanged since; Events tab — table (time, agent, process → file, Blocked/OK badge, rule) auto-refreshing every 5 s, newest first. Mockup A "Native Calm" has no file in the repos: use the token variables only (`var(--color-*)`, `--font-*`, `--space-*`, `--radius-*`), light and dark via `prefers-color-scheme`. **Rules for `app.js`:** DOM built with `createElement`/`textContent` only; never `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval`, `new Function`, inline event attributes or inline `<script>/<style>` (CSP is `default-src 'self'`); credentials come from the browser's Basic-auth prompt (no password storage in JS).

- [ ] **Step 1: Write the failing tests**: `scripts/test_tokens.py` (unittest): `test_generates_css_without_touching_submodule` (run against a temp copy of the repo layout; `git status` of `external/guardian-core` stays clean), `test_check_passes_when_current`, `test_check_fails_when_stale`. `scripts/test_panel_static.py`: `test_app_js_uses_no_html_injection_apis` (regex over `web/app.js` for the forbidden list above), `test_index_html_has_no_inline_script_style_or_handlers`, `test_html_references_only_allowlisted_assets` (exactly `/app.js`, `/panel.css`, `/tokens.css`), `test_css_uses_token_variables_for_colors` (no `#RRGGBB` literals in `panel.css`). Run `python3 -I -B -m unittest discover -s scripts` → Expected: FAIL.
- [ ] **Step 2: Implement** `scripts/tokens.py`, generate `web/tokens.css`; write the panel files.
- [ ] **Step 3: Run the unit tests** → PASS; `python3 -I -B scripts/tokens.py --check` exits 0.
- [ ] **Step 4: Manual check in a browser** (use the `claude-in-chrome` or built-in browser skill if available, otherwise ask the owner to look): start `guardian-server` in plain-HTTP loopback mode with a scratch data dir and `GUARDIAN_ADMIN_PASSWORD`, open `http://127.0.0.1:<port>/`, log in, paste the spec's example policy, save (valid), publish → badge shows "Active v2"; save a policy with an empty matcher → error list shows `rules[0].processes[2]: empty matcher`; post an event with `file` = `<img src=x onerror=alert(1)>` through `curl` with a token → it renders as literal text. Record results in the PR description with a screenshot path or description.
- [ ] **Step 5: Add CI job `tokens`** (ubuntu-24.04, `actions/checkout` with submodules, `actions/setup-python@v5` Python 3.9: `python3 -I -B -m unittest discover -s scripts` and `python3 -I -B scripts/tokens.py --check`).
- [ ] **Step 6: Commit** (`feat: add admin web panel`, `ci: add tokens and panel checks`), open **PR D**; checks green; **ask the owner, then squash-merge**. Then (ask first) re-apply rulesets adding `tokens`.

### Task 15: Documentation

**Files:**
- Create: `docs/api.md`, `docs/adr/0002-windows-service-nssm.md`
- Modify: `README.md`, `CLAUDE.md` (append "Build & test"), `docs/adr/0001-server-dependencies.md` only if a pin changed
- Branch: `feature/WRD-14-server-deploy`.

**Interfaces:**
- Produces: `docs/api.md` — the contract section of this plan, expanded with `curl` examples, status/error table, ETag rules and the SPKI pin procedure (source of truth for Plan 4). README — purpose, link to the design spec, Mermaid architecture diagram (agent ↔ `Api` ↔ stores ↔ `data/`; panel; guardian-core), build/test/lint/coverage commands, configuration table (env vars, `config.example.json`), CLI reference, security notes (threat model, limitations from this plan), deploy overview, roadmap (SQLite storage, per-agent revocation list in UI, policy history/rollback, rate limits per agent, mTLS, event de-duplication, signed policies). ADR-0002: NSSM as the Windows service host (why not a native service/WinAPI per spec, why not `sc.exe` alone), consequences (NSSM must be installed on the VPS; log rotation by NSSM).

- [ ] **Step 1: Write a failing docs check** `scripts/test_docs.py`: every route and error code string in `src/api.cpp` (`"/api/v1/..."`, `"not_found"`, …) must appear in `docs/api.md`; README contains the headings `Architecture`, `Configuration`, `Security notes`, `Roadmap` and a ```` ```mermaid ```` block. Run → Expected: FAIL.
- [ ] **Step 2: Write the docs**, run the check → PASS (`python3 -I -B -m unittest discover -s scripts`).
- [ ] **Step 3: Commit** — `git commit -m "docs: add API reference, README and service ADR"`.

### Task 16: VPS runbook, scripts and deploy workflow

**Files:**
- Create: `docs/vps-setup.md`, `scripts/install-service.ps1`, `scripts/apply-update.ps1`, `.github/workflows/deploy.yml`
- Modify: `.gitignore` if needed (no cert, key, config or `data/` in the repo)

**Interfaces:**
- `docs/vps-setup.md` is a checklist the owner and Claude walk through together (Claude cannot reach the VPS): (1) OpenSSH Server install, key-only auth (`PasswordAuthentication no`), default shell PowerShell, a dedicated low-privilege deploy user; (2) Windows Firewall: allow TCP 8443 and 22 only; (3) install VC++ redistributable and NSSM (`winget`); (4) create `C:\guardian\{bin,data,web,incoming}` with ACLs limited to SYSTEM, Administrators and the deploy user (`icacls`); (5) generate the certificate on the VPS: `guardian-server cert generate --host <vps-ip> --out-dir C:\guardian\data\tls` and record the printed pin (the pin is public, it goes to the agent Settings and `README`); (6) create `C:\guardian\config.local.json` by hand from `config.example.json` with the admin password (never in chat or in the repo); (7) `scripts/install-service.ps1` registers service `GuardianServer` via NSSM (working dir `C:\guardian`, stdout/stderr to `C:\guardian\logs` with rotation, auto-start, restart on failure); (8) GitHub: environment `production` with the owner as required reviewer, secrets `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_KNOWN_HOSTS` (host key line, so SSH never trusts on first use); (9) first token: `guardian-server token add mac-eugene`.
- `scripts/apply-update.ps1 -Zip <path>`: stop service → back up `bin` to `bin.prev` → expand zip into `bin`/`web` → start service → poll `https://127.0.0.1:8443/healthz` for 30 s (certificate check skipped for loopback only) → on failure restore `bin.prev`, restart, exit 1. `deploy.yml`: triggers `push` tags `v*.*.*` and `workflow_dispatch`; job `build` (windows-latest, preset `windows` Release, `ctest`, zip `guardian-server.exe` + `web/` as artifact) → job `deploy` (ubuntu-latest, `environment: production`, `permissions: contents: read`; writes the key and `known_hosts` from secrets to `$RUNNER_TEMP` with mode 600, `scp` the zip to `C:/guardian/incoming/`, `ssh … powershell -File C:\guardian\scripts\apply-update.ps1 -Zip …`; `StrictHostKeyChecking=yes`; secrets never echoed; key file removed in an `if: always()` step).

- [ ] **Step 1: Write the failing check** `scripts/test_deploy_files.py`: `deploy.yml` contains `environment: production`, `StrictHostKeyChecking=yes`, `known_hosts`, no `StrictHostKeyChecking=no`, no `${{ secrets.* }}` inside an `echo`/`run` command line except assignment to `env:`; `apply-update.ps1` mentions `bin.prev` and `healthz`; `docs/vps-setup.md` contains the nine numbered steps. Run → Expected: FAIL.
- [ ] **Step 2: Write the files**, run the check → PASS.
- [ ] **Step 3: Open PR E** (`docs: API reference, VPS runbook and deploy workflow`), checks green (`gh pr checks <n> --watch`), **ask the owner, then squash-merge**.
- [ ] **Step 4: VPS preparation with the owner (ask before each step; nothing here is automated by Claude)** — the owner runs `docs/vps-setup.md` steps 1–7 and 9 on the VPS (Claude supplies exact commands and reviews outputs the owner pastes, never the password or key), sets the GitHub environment and secrets (step 8), and reports the printed SPKI pin. Expected: `Test-NetConnection <vps-ip> -Port 8443` succeeds from the Mac after the first deploy.

### Task 17: Release `v0.1.0` and live smoke test

**Files:** none (release mechanics).

**Interfaces:**
- Produces: tag `v0.1.0` on `main` of `guardian-server`, a running service on the VPS, the SPKI pin and agent token procedure for Plan 4.

- [ ] **Step 1: Final verification on `develop`** — `ctest --preset macos`, `scripts/coverage.sh` (≥ 80 %), `scripts/lint.sh`, `python3 -I -B -m unittest discover -s scripts` and `-s tooling/claude`, all green; `git submodule status` shows `guardian-core` at `v0.1.0`.
- [ ] **Step 2: Release PR (ask the owner first)** — `gh pr create --base main --head develop --title "chore: release v0.1.0"`; merge when green with a merge commit (as `protected-main` allows).
- [ ] **Step 3: Tag (ask the owner first — this publishes and triggers the production deploy)** — `git switch main && git pull --ff-only && git rev-parse main origin/main` (equal) `&& git tag -a v0.1.0 -m "guardian-server v0.1.0" && git push origin v0.1.0`; approve the `production` environment in GitHub; watch `gh run watch`.
- [ ] **Step 4: Live smoke test from the Mac** (pin and password supplied by the owner; do not paste the password into chat — the owner runs the `curl` lines with `!`): `curl --pinnedpubkey "sha256//<pin>" -k https://<vps-ip>:8443/healthz` → `{"status":"ok","version":"0.1.0"}`; unauthenticated `GET /` → `401`; `curl -u admin https://…/api/v1/admin/policy` → active v1; agent `GET /api/v1/policy` with the first token → `200`, `ETag: "v1"`, repeated with `If-None-Match: "v1"` → `304`. Publish the spec's example policy from the panel in a browser → "Publish v2" works, agent `GET` now returns `ETag: "v2"` (spec §9 steps 1–2, server side).
- [ ] **Step 5: Hand off** — report to the owner: the server contract is in `guardian-server/docs/api.md`; Plan 4 needs the VPS address, the SPKI pin, and an agent token (issued by the owner, never stored in a repo).
