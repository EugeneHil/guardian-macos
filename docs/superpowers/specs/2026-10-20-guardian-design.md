# Guardian — Lightweight Endpoint DLP for macOS — Design

> Formerly Warden.

Date: 2026‑10‑20 · Status: approved

Decision tags: **[owner]** — product owner's decision; **[proposed]** — assistant's call, open to challenge; **[builder]** — left to the implementer.

---

## 1. What and why

**Guardian** is an Endpoint DLP (Data Loss Prevention) product. It protects developers' sensitive files on macOS (`.env` files, SSH keys) from being read by browsers and AI tools — the channel through which secrets most often leak, e.g. by dragging a file into a chat.

Policies are managed centrally on a server and enforced on endpoints. The Mac agent is built on native macOS system facilities (Endpoint Security, System Extensions, XPC); access decisions are made by a cross‑platform C++17 rule engine shared by the agent and the server.

First release (v0.1): a lightweight product with production‑grade architecture, delivered in about one week **[owner]**. Priority is quality, clean architecture and reliability over feature count.

**v0.1 is done when** the acceptance scenario in §9 passes end‑to‑end, all three repositories have green CI, the design system is in place, and each README contains an architecture diagram and roadmap.

## 2. Goals, non‑goals, anti‑goals

**Goals**
- The Mac agent denies opening protected files (`.env`, `~/.ssh`) to **processes listed in the policy's blocklist** (browsers, AI apps, any process the admin adds). Everything else is allowed **[owner]**. Decisions are based on **metadata only** — file contents are never inspected **[owner]**.
- Policies are stored centrally on a server (Windows VPS) and delivered to the agent over HTTPS **[owner]**.
- A single C++17 rule engine runs both on the server (Windows) and in the agent (macOS) **[owner]**.
- Fail‑open: an agent failure must never block the user's work.
- TDD, strict rules, maximum automation of the development process.

**Threat model for v0.1 [owner]:** accidental leakage by a non‑malicious user. Not defended in v0.1 (roadmap): bypass by renaming/copying/hard‑linking (`.env` → `env.txt`), uninstalling or stopping the agent, tampering with the policy on the device, a malicious user.

**Non‑goals for v0.1** (listed as roadmap in README) **[owner]**
- NetworkExtension / network filtering, TLS interception (MITM).
- File content inspection (secret regexes).
- MDM, pkg/productbuild installer, self‑update, notarization; server‑signed policies; tamper protection.
- Official Linux support, iOS client.
- A VPN tunnel between agent and server — plain HTTPS only **[owner]**.

**Anti‑goals** (failure even if everything "works")
- The agent slows the system down or breaks it on failure (e.g. a missed ES deadline).
- A secret (TLS key, token, admin password) lands in a public repository.
- Muddled architecture: logic inside ES callbacks, god objects, no tests.
- The admin panel on a public server reachable without authentication.

## 3. Constraints
- **No paid Apple Developer Program for v0.1 [owner].** `com.apple.developer.endpoint-security.client` is a restricted entitlement that a free Personal Team cannot obtain, so the extension and app are **ad‑hoc signed** and run with SIP disabled, `nvram boot-args="amfi_get_out_of_my_way=1"` and `systemextensionsctl developer on`. **[proposed]** All of this is done **only inside a macOS VM** (UTM / Apple Virtualization) with a "clean" snapshot; the host system stays untouched. **The first plan task is a spike** proving that an ad‑hoc signed ES system extension activates in that VM.
  - Consequence: no Team ID, so the XPC code‑signing requirement can only pin the bundle identifier (+ ad‑hoc cdhash where practical). This is a documented v0.1 limitation; with a paid certificate it becomes `anchor apple generic and certificate leaf[subject.OU] = <TEAMID>`.
- **Server runs on a Windows VPS [owner].** No domain → self‑signed certificate; the agent validates it via SPKI pinning **[proposed]**. The VPS is not prepared yet; setting it up is a plan task (§8) **[owner]**.
- **AI tooling budget:** Claude subscription + $100 of cloud session credits valid until Nov 5; no budget beyond that **[owner]**.
- **Platforms:** macOS (agent) and Windows (server) are supported. CoreCpp and GuardianServer must also build and pass tests on Linux **as an unofficial dev build only**, so cloud sessions (Linux) can work on them; Linux is not in CI and not supported **[owner]**.
- **GitHub, public repositories [owner].**

## 4. Architecture

```
┌──────────────────────── Mac (VM for ES debugging) ───────────────────────┐
│ GuardianApp (SwiftUI, menu bar, MVVM)                                      │
│   ├─ DesignSystem/ (folder, generated tokens)                            │
│   ├─ PolicySync: HTTPS + SPKI pinning ──────────────┐                    │
│   ├─ EventUploader ─────────────────────────────────┤                    │
│   └─ XPC client ──(NSXPCConnection .privileged)──┐  │                    │
│                                                  ▼  │                    │
│ DlpExtension (System Extension, Endpoint Security)  │                    │
│   ├─ ES client: AUTH_OPEN, fast path, early respond │                    │
│   ├─ PolicyStore: on‑disk policy cache              │                    │
│   ├─ EventQueue: bounded event queue                │                    │
│   └─ CoreBridge (Obj‑C++) ──► CoreCpp (C++17)       │                    │
└─────────────────────────────────────────────────────┼────────────────────┘
                                                      │ HTTPS :8443
┌──────────────── Windows VPS ────────────────────────▼────────────────────┐
│ GuardianServer (C++17, CMake) ──► CoreCpp (same code)                      │
│   ├─ /api/v1/policy, /api/v1/events (agent, per‑agent token)             │
│   ├─ /api/v1/admin/* (panel, Basic Auth over HTTPS)                      │
│   └─ web panel: static HTML/CSS/JS, tokens.css                           │
└──────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Components (Tuist) [owner]
Four main components. No fine‑grained feature modules and no DI container in v0.1; DI is done via protocols and initializer injection — enough for testability.

1. **GuardianApp** — menu bar app (`MenuBarExtra`), SwiftUI, MVVM. Activates/deactivates the system extension (`OSSystemExtensionRequest`); pulls the policy from the server every **10 s** plus a "Sync now" action **[proposed]**, using `ETag`/`If-None-Match`, and pushes it to the extension over XPC; drains events from the extension and uploads them; posts block notifications (`UserNotifications`). Contains the `DesignSystem/` folder **[proposed]**.
   **The app (not the extension) fetches the policy [proposed]:** networking and UI are easier to test, and enforcement does not depend on the app because the extension keeps a cache.
2. **CoreBridge** — isolated Objective‑C++ framework; the only place where Swift meets C++. Exposes only Objective‑C/Swift types (`WDPolicy`, `WDAccessRequest`, `WDDecision`).
3. **DlpExtension** — Endpoint Security system extension (runs as root, launched by sysextd).
4. **CoreCpp** — pure C++17, no platform dependencies, built with CMake. In Tuist it is consumed as a prebuilt static library produced by a CMake script in a pre‑build step **[builder]**.

The extension's testable logic (ES event → `AccessRequest` mapping, queue, policy cache, deadline handling) lives in separate Swift files with no dependency on `EndpointSecurity`; those files are additionally compiled into the `DlpExtensionTests` target. The ES client itself is hidden behind `ESClientProtocol` **[proposed]**.

### 4.2 CoreCpp — policy & engine

**Policy format v1** [proposed; schema is extensible]:
```json
{
  "schemaVersion": 1,
  "version": 3,
  "rules": [
    { "id": "secrets-from-browsers-and-ai",
      "description": ".env files and SSH keys must not be read by browsers and AI apps",
      "targets": ["**/.env", "**/.env.*", "~/.ssh/**"],
      "action": "deny",
      "processes": [
        { "teamId": "EQHXZ8M8AV" },
        { "signingIdPrefix": "com.google.Chrome" },
        { "signingIdPrefix": "com.apple.Safari" },
        { "signingIdPrefix": "com.openai.chat" },
        { "signingIdPrefix": "com.anthropic.claude" },
        { "path": "/usr/bin/python3" }
      ] }
  ]
}
```
- Semantics: **blocklist** — a request is denied iff its file path matches a rule's `targets` **and** the process matches one of the rule's `processes`. Default is allow **[owner]**. (Exact Team IDs / signing IDs of target apps are verified with `codesign -dv` during implementation **[builder]**.)
- A process matcher matches when **all** its specified fields match (`teamId`, `signingId`, `signingIdPrefix`, `path`). It is evaluated against the opening process **and** its responsible process (from `es_process_t.responsible_audit_token`), so browser helper/renderer processes are caught via their parent app **[proposed]**.
- `~` expands to `/Users/*` [proposed] — ES runs as root and all users must be protected.
- Globs: `*` does not cross `/`; `**` matches any number of segments. A small custom matcher (no regex), fully tested.
- Validation returns a list of errors with JSON paths (`rules[0].processes[2]: empty matcher`). The server refuses to publish an invalid policy.
- Public API (sketch): `Result<Policy> parsePolicy(std::string_view json)`; `Decision evaluate(const Policy&, const AccessRequest&)` where `Decision {allow|deny, ruleId}`; `bool isPotentiallyProtected(std::string_view path)` — fast prefilter for ES.
- JSON via nlohmann/json pulled with CMake FetchContent at a pinned tag [proposed]; builds on macOS, Windows and (dev only) Linux via CMake presets.

### 4.3 DlpExtension — Endpoint Security
- Subscribes to `ES_EVENT_TYPE_AUTH_OPEN`; mutes its own process (`es_mute_process`).
- **Inverted target‑path muting is not used:** it supports only prefixes/literals, while `**/.env` can be anywhere. All `AUTH_OPEN` events are received; responses use `es_respond_flags_result` (allowed flags = requested flags, or 0 to deny).
- **Fast path:** if the path cannot match any rule (`isPotentiallyProtected`), respond immediately with all flags and `cache=true`. The ES cache is per (process, file), so event volume stays high system‑wide; the fast path must therefore be allocation‑free and O(path length). Full evaluation runs only for candidates. On policy change, call `es_clear_cache`.
- **Deadlines:** a missed deadline makes ES kill the client (it does not "allow"). Hence: nothing on the event path may block (see the Swift Concurrency exception in §7); the response is sent synchronously in the handler for fast‑path events; for candidates a watchdog responds `allow` well before the deadline (e.g. at 50 % of `deadline`). Where the OS supports it (macOS 27+), the client also sets `es_set_deadline_miss_mode(ES_DEADLINE_MISS_MODE_FAIL_OPEN)`, so a missed deadline allows the open instead of killing the client.
- **Fail‑open:** extension crash / `kill -9` → kernel allows access, sysextd restarts the extension; at startup the policy cache is loaded asynchronously and until it is loaded every event gets `allow`; invalid cache → `allow` everything and report the error.
- Policy cache at `/Library/Application Support/Guardian/policy.json` (root, 0600), written atomically.
- Events: in‑memory ring buffer of 1000 entries [proposed] with deduplication of identical (process, file) pairs within 5 s.
- XPC: Mach service declared in `NSEndpointSecurityMachServiceName`; incoming connections checked via `setCodeSigningRequirement` (bundle identifier in v0.1, see §3). Protocol: `apply(policyData)`, `currentPolicyVersion()`, `drainEvents(max)`, `subscribe(events)` for notifications.
- Logging via `Logger` (subsystem `…guardian`), paths marked `privacy: .private`.

### 4.4 GuardianApp — UI
- Menu bar popover **following mockup A "Native Calm" [owner]**: status header "Protection active" with ON/OFF badge; "Policy vN · synced X s ago" line + "Sync now"; recent events (dot, "process → file", path·time, "Blocked"/"OK" badge); footer "All events…" / "Settings".
- "All events" window with a list and a "blocked only" filter [builder].
- Settings: server URL, agent token (Keychain), SPKI pin, Install/Uninstall extension buttons.
- States: extension not installed / awaiting approval in System Settings / active / server unreachable (showing the last cached policy).
- MVVM: View → ViewModel (`@Observable`, `@MainActor`) → service protocols (`PolicyServicing`, `ExtensionManaging`, `EventStreaming`, `NotificationPosting`).

### 4.5 GuardianServer
- C++17, CMake, cpp-httplib + OpenSSL [proposed]; dependencies via vcpkg manifest on Windows, system packages / FetchContent on the Linux dev build. Code avoids WinAPI.
- **Agent identity [proposed]:** one token per agent. Tokens are generated by the admin (CLI subcommand `guardian-server token add <agentId>`), stored hashed in `data/agents.json`, revoked by removal. `agentId` is derived from the token on the server, not trusted from the payload.
- **Endpoints** (JSON):

  | Method & path | Caller | Purpose |
  |---|---|---|
  | `GET /api/v1/policy` | agent (`Authorization: Bearer <agent-token>`) | 200 + active policy with `ETag: "v3"`, or 304 |
  | `POST /api/v1/events` | agent | event batch `[{ts, process{path,signingId,teamId}, responsible{…}, file, decision, ruleId}]` |
  | `GET /api/v1/admin/policy` | admin (Basic Auth) | active policy + draft |
  | `PUT /api/v1/admin/policy/draft` | admin | save draft; response = CoreCpp validation result |
  | `POST /api/v1/admin/policy/publish` | admin | valid draft → version N+1 |
  | `GET /api/v1/admin/events?limit=` | admin | recent events |
  | `GET /` | admin | web panel (static) |

- **Storage [proposed]:** policies as `data/policies/vN.json` + active version pointer; events in `data/events.jsonl` with rotation. Accessed through a `Storage` interface (SQLite later).
- **Secrets:** TLS cert/key paths, admin password — from environment variables or `config.local.json` (gitignored); only `config.example.json` is committed.
- **Web panel:** single HTML page, vanilla JS, `tokens.css`, mockup A. Screens: "Policy" (rules table, draft JSON editor with validation result, "Publish vN+1") and "Events" (feed).

### 4.6 Design system [owner: direction A "Native Calm"]
- Single source of truth: `guardian-core/design-tokens/tokens.json` — semantic colors (light/dark), typography, spacing, radii.
- Generator `generate.py` (Python 3, stdlib only) → `Tokens.swift` (GuardianApp/DesignSystem) and `tokens.css` (panel). Generated files are committed in consuming repos; CI checks they are up to date **[proposed]**.
- SwiftUI components: `StatusHeader`, `EventRow`, `Badge`, `PolicyChip`, `WDButton`, each with `#Preview` in light and dark mode.

## 5. Repositories & branching [owner]
- `guardian-core` — CoreCpp + design-tokens. CI: macOS + Windows.
- `guardian-macos` — Tuist project; `guardian-core` as a submodule pinned to a tag. CI: macOS.
- `guardian-server` — server + panel; `guardian-core` as a submodule pinned to a tag. CI: Windows.
- This document is committed to `guardian-macos/docs/superpowers/specs/`; other repos link to it from their README **[proposed]**.
- Branches: `main`, `develop`. Work goes into `feature/WRD-<n>-<slug>` (also `fix/…`, `chore/…`); PRs target **`develop`**. Releases: PR `develop → main` + tag `vX.Y.Z`.
- Protection on `main`/`develop`: PR only, green CI required, linear history, no force push.
- Conventional Commits, PR template, CODEOWNERS.

## 6. Secrets & `.gitignore` [owner]
- **No secrets, three layers:** pre-commit hook (`pre-commit` + gitleaks); gitleaks in CI; GitHub secret scanning + push protection.
- Claude Code `PreToolUse` hook blocks the agent from reading/writing `.env*`, `*.pem`, `*.key`, `*.p12`, `config.local.json`, and from `git commit`/`git push` on `main`/`develop`.
- **`.gitignore`:** `.DS_Store`; `DerivedData/`, `xcuserdata/`, `*.xcuserstate`, Tuist‑generated `*.xcodeproj`/`*.xcworkspace`, `Derived/`; `build/`, `cmake-build-*/`, `out/`; `.vs/`, `*.user`; `vcpkg_installed/`; `.env*`, `*.pem`, `*.key`, `*.p12`, `*.cer`, `config.local.json`, `data/`; `.superpowers/`; `*.profraw`, `coverage/`.

## 7. TDD, quality, strict rules [owner]
- TDD is mandatory (superpowers:test-driven-development): test first, then code.
- CI coverage gates: CoreCpp ≥ 90 % lines (llvm-cov on macOS); Swift logic (ViewModels, services, extension's testable logic) ≥ 80 %; server handler logic ≥ 80 %.
- **Swift Concurrency only [owner]:** all Swift code uses async/await, actors, `AsyncStream`/`AsyncSequence`, `Task` and structured concurrency. No GCD (`DispatchQueue`), `OperationQueue`, completion‑handler APIs or Combine in our own code. Callback‑based system APIs (XPC, `OSSystemExtensionRequest`, `URLSession` delegate for pinning) are wrapped once at the boundary with `withCheckedThrowingContinuation`/`AsyncStream`. Shared mutable state lives in actors or, where synchronous access is required, in `Synchronization.Mutex`/atomics. UI state is `@MainActor`.
  - **The only exception:** the ES handler block is invoked synchronously by EndpointSecurity and must respond before the deadline, so it never `await`s. It reads the current policy snapshot through a `Mutex`, answers the fast path inline, and hands candidates to an actor‑based evaluator whose watchdog is a `Task` with `Task.sleep`. Events are delivered to the rest of the extension via `AsyncStream`.
  - The watchdog can only fire when a cooperative‑pool thread is free. Therefore the blocking responsible‑process lookup (libproc/Security) is cached per process instance and serialized through one actor, so it holds at most one pool thread, and the coordinator caps candidate evaluations in flight (over the cap → immediate allow). The candidate deadline passed to the watchdog is capped at 2 s (`ESDeadline.cap`), so the watchdog allows within 1 s. Consequently the VM (and any host) needs at least 2 vCPUs: with a 1‑vCPU cooperative pool a blocked lookup leaves no thread for the watchdog.
- Warnings are errors: Swift 6 language mode, strict concurrency `complete`; `-Wall -Wextra -Wpedantic -Werror` (MSVC `/W4 /WX`); clang-tidy + clang-format; SwiftLint `--strict` + SwiftFormat `--lint`.
- Each repo has a `CLAUDE.md`: stack, build/test commands, rules (TDD, branching, no secrets, no new dependencies without an ADR, no force unwraps / `try!`). Short ADRs in `docs/adr/`.
- Manual e2e checklist `docs/e2e-checklist.md` for the VM; the §9 scenario is run on every release.

## 8. Automation
- **Local:** superpowers pipeline — writing-plans → subagent-driven-development (each task in its own worktree/branch) → code review → PR to `develop` via `gh`.
- **Models [proposed]:** plan implementation by Sonnet; planning and review by Opus — to save budget.
- **Cloud sessions [proposed]:** only `guardian-core` and `guardian-server` tasks (Linux dev build); used for isolated plan tasks in parallel with local work. When credits run out, continue locally.
- **GitHub Actions:** build, tests, coverage, linters, gitleaks, token freshness check, `tuist graph` artifact; Dependabot for Actions and submodules.
- **VPS preparation (plan task, done together with the owner) [owner]:** install OpenSSH Server with key‑only auth; open 8443 in Windows Firewall; generate the self‑signed TLS cert and compute the SPKI pin (script in `guardian-server/scripts/`); register the server as a Windows service (NSSM or `sc.exe` [builder]).
- **Server deployment:** on tag `vX.Y.Z` in `guardian-server` → build on `windows-latest` → deploy to the VPS over SSH using a key from GitHub Secrets → restart the service. No self‑hosted runner on the VPS (unsafe for a public repo).

## 9. v0.1 acceptance scenario [owner]
1. **Panel on VPS:** draft policy with the rule "`.env` and `~/.ssh` are blocked for browsers and AI apps"; validation green; "Publish v2".
2. **Mac:** within ≤ 15 s (or immediately via "Sync now") the menu bar shows "Policy v2".
3. **Browser:** drag `~/proj/api/.env` into ChatGPT/Claude in Chrome → denied; notification shown; event visible in the popover and in the server panel. `cat ~/proj/api/.env` in Terminal → succeeds (not blocklisted).
4. **Live policy change:** `python3 -c "open('/Users/…/.ssh/id_ed25519').read()"` succeeds → in the panel add `python3` to the blocklist, publish v3 → after sync the same command fails with `PermissionError`.
5. **Failure:** `sudo kill -9 <extension pid>` → the system keeps working with no hangs; sysextd restarts the extension; it restores policy v3 from cache.
6. **Code walkthrough:** Tuist module graph, green CI in all three repos, README with diagram and roadmap.

## 10. Left to the builder
- Exactly how the CMake build of CoreCpp plugs into Tuist (pre‑build script vs. xcframework).
- Layout details of the "All events" window and Settings within mockup A.
- Concrete dependency versions — latest stable at start time; exact Team IDs / signing IDs of blocked apps.
- Bundle ID prefix (owner's GitHub handle).
- Day‑by‑day breakdown and task order — in the plan (writing-plans), starting with the ad‑hoc sysext spike.

## 11. Resolved questions (builder check)
- **Allow‑ vs. blocklist:** blocklist of processes per rule; default allow **[owner]**.
- **Threat model:** accidental leakage only in v0.1 **[owner]**.
- **Linux:** unofficial dev build for CoreCpp and GuardianServer so cloud sessions can be used **[owner]**.
- **VPS:** not prepared; setup is a joint plan task **[owner]**.
- **Signing:** ad‑hoc + AMFI off; XPC check limited to identifier; day‑one spike **[proposed]**.
- **Agent identity:** per‑agent tokens issued by admin CLI **[proposed]**.
- **Sync latency:** 10 s polling + "Sync now" **[proposed]**.
- **Matching against responsible process:** yes, to catch browser helpers **[proposed]**.
