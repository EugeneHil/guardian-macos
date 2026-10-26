# Rename Warden to Guardian Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the name Warden with Guardian in all three repositories, the deployed server and the installed agent, with no behaviour change.

**Architecture:** Each repo gets a stdlib Python "residual names" test with named groups. A task enables one group (the failing test lists every offender), renames until it passes, and ends with the repo-wide `all` group and an explicit allow-list. `guardian-core` is renamed and released first; `guardian-server` and `guardian-macos` then bump their submodule and proceed independently. Owner-only steps are separate gate tasks.

**Tech Stack:** C++17/CMake (core, server), Swift/Tuist (macos), Python 3.9 stdlib tests, GitHub Actions, NSSM on Windows Server 2022.

**Spec:** `docs/superpowers/specs/2026-10-26-guardian-rename-design.md` (in the repo `warden-macos`, renamed `guardian-macos` by Task 1). Read its "Name map" before every task.

## Global Constraints

- Names: `Guardian` (types, display), `guardian` (namespaces, paths, repos), `GUARDIAN_` (env vars, CMake options), `GRD`/`grd` (short forms), `GD*` replaces `WD*`. Exact old-to-new pairs are the spec's "Name map".
- Kept unchanged: token prefix `wdn_`, server address, SPKI pin, TLS certificate. Old git history, tags and `WRD-<n>` ticket ids are not rewritten; new tickets use `GRD-<n>`, branches `feature/GRD-<n>-<slug>` / `docs/…` / `chore/…`.
- Hard cut: no fallback to `WARDEN_*` env vars or old paths (spec decision 2). A loud refusal is allowed (Task 7).
- Old dated docs are renamed with `git mv`, text updated to the new names, and each gets the line `> Formerly Warden.` under its title (spec decision 4). Statements about commits, tags and PR numbers stay as written.
- Repo rules (every repo `CLAUDE.md`): TDD, never commit or push to `main`/`develop`, PRs to `develop`, Conventional Commits, no `--no-verify`, warnings are errors, no new dependency, never touch secrets, lint and tests before every commit. Ask the owner before every merge, ruleset change, VPS step and tag push.
- Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. PR body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Deviation from the spec's verification section: `WRD-` is NOT checked by the residual test (historical ticket ids in old docs and commit references stay). Task 1 amends the spec line.
- The guard hook blocks edits to `tooling/claude/guard.py`, `tooling/claude/test_guard.py` and `.claude/settings*.json` from inside Claude. Those edits are **owner hand edits** (`!` prefix); each task that needs one lists the exact change.

## Review Focus

1. Old env vars left on the VPS (`WARDEN_DATA_DIR`, `WARDEN_ADMIN_PASSWORD`, ...) after the upgrade: the server must refuse to start with a message naming the new variable, not silently run on defaults with an empty data dir. Test in Task 6.
2. A token store written under the old layout loads under the new data directory and the issued token still authenticates. Test in Task 6.
3. Old and new extension installed side by side in the VM (two Endpoint Security clients, double blocking, stale approval): the e2e run starts with the old one removed and checks `systemextensionsctl list` shows only the new one. Step in Task 12.
4. Stale submodule: a consumer pinned to a `warden-core` commit, or `.gitmodules` pointing at the old repo name or path, must fail CI. Residual test group `submodule` in Tasks 5 and 10.
5. `sync-shared.sh` run against an already synced repo must replace the old `.gitignore` marker block, not append a duplicate. Test in Task 2.

---

## Phase 0 — owner gate

### Task 0: Rename repositories and local folders (owner only)

**Files:** none (GitHub settings and local disk).

- [ ] **Step 1:** After the spec/plan PR (Task 1) is merged and the owner says go: rename the repos on GitHub to `guardian-core`, `guardian-macos`, `guardian-server`.
- [ ] **Step 2:** Rename local folders to `/Users/eugene/Mine/git/guardian/guardian-{core,macos,server}`; run `git remote set-url origin https://github.com/EugeneHil/guardian-<x>.git` in each (and `git config credential.helper` is repo-local, so verify `git fetch` works).
- [ ] **Step 3:** Verify and paste results: `gh api repos/EugeneHil/guardian-server/rulesets` still lists `protected-develop`, `protected-main`, `protected-release-tags`; the `production` environment and `VPS_*` secrets exist; Actions still run on a trivial push to a throwaway branch.
- [ ] **Step 4:** Restart Claude Code from the new `guardian-macos` folder (new project path; the guard hook is wired per repo, so check it fires).

Expected: old URLs redirect; all three repos green on `develop`. Every later task assumes the new paths.

---

## Phase 1 — spec and plan PR

### Task 1: Land the spec and plan under the new repo name

**Files:**
- Modify: `docs/superpowers/specs/2026-10-26-guardian-rename-design.md` (verification section already says ticket ids `WRD-<n>` are not checked)
- Create: this plan

- [ ] **Step 1:** In the branch `docs/GRD-1-rename-design` commit the plan and the spec amendment: `docs: add the Guardian rename plan`.
- [ ] **Step 2:** Push, open a PR to `develop`, ask the owner before merging.

---

## Phase 2 — guardian-core

Working dir: `guardian-core`, branches `chore/GRD-<n>-…`. Python tests run with `python3 -I -B -m unittest discover -s scripts`; add that command as a step of the existing CI job `tokens` (no new required check name).

### Task 2: Residual-names test, text rename, shared tooling

**Files:**
- Create: `scripts/test_residual_names.py`
- Modify: `.github/workflows/ci.yml` (add the unittest step to `tokens`), `README*`, `tooling/README.md`, `tooling/repo/CLAUDE.base.md`, `tooling/repo/gitignore.base`, `tooling/repo/.gitleaks.toml`, `tooling/sync-shared.sh`, `tooling/github/bootstrap-repo.sh`, `CLAUDE.md`, `docs/**` if any
- Create: `scripts/test_sync_shared.py`
- Owner hand edit: `tooling/claude/guard.py:276` message text `Blocked by warden guard` → `Blocked by guardian guard`; `tooling/claude/test_guard.py` fixture paths `/r/warden-core` → `/r/guardian-core`, `/r/warden-macos` → `/r/guardian-macos`, `../warden-macos` → `../guardian-macos`

**Interfaces:**
- Produces: `GROUPS: dict[str, Group]` in `scripts/test_residual_names.py`, where `Group = (pattern: re.Pattern, paths: callable(str)->bool, enforced: bool)`; patterns match case-insensitively against tracked file contents (`git ls-files`, text files only) and tracked path names. `ALLOW: dict[str, set[str]]` maps a group to repo-relative paths exempt from it. One `unittest` method per group named `test_group_<name>`, skipped while `enforced` is False. The same shape is used in all three repos; `pattern` is always `warden|wdn(?!_)`.
- Produces: groups for core: `text` (md, yml, toml, sh, json under `tooling/`, `.github/`, root docs), `code` (cpp, hpp, CMake, py under `design-tokens/`, `cmake/`, `include/`, `src/`, `tests/`), `submodule` (n/a in core), `all` (everything tracked).

- [ ] **Step 1:** Write `scripts/test_residual_names.py` with all groups defined, `text` enforced. Write `scripts/test_sync_shared.py::test_old_marker_block_is_replaced_not_duplicated` (temp repo whose `.gitignore` holds a block between `# --- warden shared ignores` and `# --- end warden shared ignores`; run `tooling/sync-shared.sh` twice; assert exactly one `guardian` block and zero `warden` lines) and `test_sync_is_idempotent`.
- [ ] **Step 2:** Run both: `python3 -I -B -m unittest discover -s scripts` → FAIL (residual `text` offenders listed; sync test fails).
- [ ] **Step 3:** Rename text in the listed files (display names, URLs, comments). In `tooling/repo/gitignore.base` use `# --- guardian shared ignores …` and `# --- end guardian shared ignores`. In `sync-shared.sh` recognize the old marker once: if the old block exists, delete the lines from old start marker through old end marker, then append the new block (use a small `python3 -I -B` snippet for the replacement; macOS sed is unsuitable). Keep idempotency.
- [ ] **Step 4:** Owner hand-edits the guard files as listed (exact text above) and runs `python3 -I -B -m unittest discover -s tooling/claude`.
- [ ] **Step 5:** Re-run the unittest command → PASS; `scripts/lint.sh` clean. Commit `chore: rename Warden to Guardian in docs and tooling`; push; PR; ask before merge.

Expected: `text` group passes; `code` and `all` still skipped.

### Task 3: Code rename — namespace, headers, CMake, tokens

**Files:**
- Modify (git mv first): `include/warden/*.hpp` → `include/guardian/*.hpp` (engine, glob, path, policy, policy_parser, version); all of `src/`, `tests/`, `CMakeLists.txt`, `CMakePresets.json`, `cmake/*.cmake`, `design-tokens/**` (names/comments only; regenerate generated files)
- Modify: `scripts/test_residual_names.py` (enforce `code`)

**Interfaces:**
- Produces (consumed by Tasks 6 and 11): namespace `guardian`; headers `<guardian/engine.hpp>`, `<guardian/glob.hpp>`, `<guardian/path.hpp>`, `<guardian/policy.hpp>`, `<guardian/policy_parser.hpp>`, `<guardian/version.hpp>`; CMake targets `guardian_core`, `guardian::core` (alias), `guardian_tests`, `guardian_alloc_tests`, `guardian_warnings`; options `GUARDIAN_BUILD_TESTS`; version variable `GUARDIAN_CORE_VERSION`; library file `libguardian_core.a`. API names inside the namespace (`parsePolicy`, `Engine`, `evaluate`, ...) are unchanged.

- [ ] **Step 1:** Set `code` to `enforced=True`; run `python3 -I -B -m unittest discover -s scripts` → FAIL listing offenders.
- [ ] **Step 2:** Rename the tests first (`tests/` includes, `warden::` → `guardian::`), run `ctest --preset macos` → FAIL (headers/namespace missing).
- [ ] **Step 3:** `git mv include/warden include/guardian`; rename namespace, includes, CMake names and options everywhere; run `python3 -I -B design-tokens/generate.py` and commit regenerated files if they changed.
- [ ] **Step 4:** Verify: `cmake --preset macos && cmake --build --preset macos && ctest --preset macos`, `scripts/lint.sh`, `scripts/coverage.sh` (≥ 90 %), `python3 -I -B design-tokens/generate.py --check`, residual test → all PASS. The Windows preset is verified by CI only.
- [ ] **Step 5:** Enforce `all` with `ALLOW = {"all": {<this repo's historical files if any>}}`; the only legitimate leftovers are none expected in core. Commit `refactor: rename the warden namespace and targets to guardian`; push; PR; ask before merge.

### Task 4: Release guardian-core v0.2.0 (owner gate)

- [ ] **Step 1:** After the Task 3 PR merges: `git pull --ff-only` on `main` path as in HANDOFF (release PR `develop → main`, verify `git rev-parse main origin/main`), then the owner pushes tag `v0.2.0`. Claude does not push the tag.

---

## Phase 3 — guardian-server

Working dir: `guardian-server`. Needs core v0.2.0. Python tests: `scripts/` (CI: `unittest discover -s scripts`). Add `scripts/test_residual_names.py` in the same shape as Task 2 with groups `submodule`, `cpp`, `config`, `scripts`, `docs`, `all`.

### Task 5: Submodule and C++ namespace

**Files:**
- Modify: `.gitmodules` (`external/guardian-core`, URL `https://github.com/EugeneHil/guardian-core.git`), `git mv external/warden-core external/guardian-core`, pin at tag `v0.2.0`; `CMakeLists.txt`, `CMakePresets.json`, `src/**`, `tests/**` namespaces/includes (`warden::server` → `guardian::server`, `warden::` → `guardian::`, `<warden/…>` → `<guardian/…>`), CMake targets `guardian_server_lib`, option `GUARDIAN_SERVER_BUILD_TESTS`, macros `GUARDIAN_SERVER_VERSION`/`SOURCES`/`SOURCE_DIR`, `scripts/tokens.py`, `scripts/test_tokens.py` paths
- Create: `scripts/test_residual_names.py`

- [ ] **Step 1:** Create the residual test; enable `submodule` and `cpp`; run → FAIL.
- [ ] **Step 2:** Update tests in `tests/` to the new namespace/includes → build FAILS.
- [ ] **Step 3:** Repoint the submodule (`git submodule deinit`, `git mv`, `git config -f .gitmodules …`, `git submodule update --init`, checkout tag `v0.2.0`), then rename production code.
- [ ] **Step 4:** Verify `cmake --preset macos`, build, `ctest --preset macos`, `scripts/lint.sh`, `scripts/coverage.sh`, `python3 -I -B -m unittest discover -s scripts` → PASS. Commit `refactor: rename the namespace and move to guardian-core`; PR; ask before merge.

### Task 6: Configuration surface — env vars, names, loud refusal

**Files:**
- Modify: `src/config.cpp` (env names `GUARDIAN_HOST|PORT|TLS_CERT|TLS_KEY|DATA_DIR|WEB_ROOT|ADMIN_PASSWORD`), `src/cli.cpp` (macros `GUARDIAN_CONFIG_FILE`, `GUARDIAN_KEY_FILE`, default `C:\guardian\config.local.json` on Windows, usage text `guardian-server`, `GUARDIAN_DATA_DIR`), `src/admin_routes.cpp` (header `X-Guardian-Request` / lowercased lookup `x-guardian-request`, message, `Basic realm="Guardian"`), `src/version.*` comments, `web/**` (panel JS/HTML sending the header), `tests/**`
- Modify: `docs/api.md` (header name)

**Interfaces:**
- Produces: `std::optional<std::string> legacyEnvVarProblem(const EnvLookup& env)` declared in `src/config.hpp` — returns a message naming every set `WARDEN_*` variable and its `GUARDIAN_*` replacement, or `std::nullopt`; `serve` calls it first and exits non-zero (exit code 2) printing the message to stderr. `EnvLookup` is the existing env-reading function type in `config.cpp` (reuse it; do not add a new one).

- [ ] **Step 1:** Write failing tests: `config tests` — each `GUARDIAN_*` variable is read; `legacyEnvVarProblem` with `WARDEN_DATA_DIR` set returns a message containing both `WARDEN_DATA_DIR` and `GUARDIAN_DATA_DIR`; with none set returns `std::nullopt`; CLI test `serve` with `WARDEN_PORT` set exits 2 and prints the message; admin route test expects `X-Guardian-Request: 1` accepted and `X-Warden-Request: 1` rejected with `400 bad_request`; realm test expects `Basic realm="Guardian"`.
- [ ] **Step 2:** Run `ctest --preset macos` → FAIL.
- [ ] **Step 3:** Implement the renames and `legacyEnvVarProblem`; update `web/` and `docs/api.md`.
- [ ] **Step 4:** Add the token-store compatibility test `LegacyLayoutTokenStoreTest.TokenIssuedUnderOldDataDirStillAuthenticates` in `tests/`: build a data dir by copying a fixture generated with `warden-server` v0.1.1 (create the fixture from the released binary or from the store's documented file format; commit only non-secret hashes of a throwaway token), start the store at a new path, assert authentication with the throwaway token succeeds. If any file name or salt derives from the old name, stop and report to the owner instead of continuing.
- [ ] **Step 5:** Verify tests, lint, coverage, the Python tests, residual `config` group → PASS. Commit `refactor: rename configuration surface to Guardian`; PR; ask before merge.

### Task 7: Scripts, workflows, docs, VPS runbook

**Files:**
- Modify: `scripts/apply-update.ps1`, `scripts/install-service.ps1` (`GuardianServer`, `C:\guardian\…`, `guardian-server.exe`, `Stop-/Start-GuardianService`, `GuardianLoopbackProbe`, firewall rule `Name`s, `guardian-deploy`), `.github/workflows/deploy.yml` (`C:/guardian/incoming`, `C:\guardian\scripts\apply-update.ps1`, artifact `guardian-server-zip`), `.github/workflows/ci.yml`, `tooling/**` (owner hand edit for guard files as in Task 2), `docs/vps-setup.md`, `docs/adr/*`, `README.md`, `CLAUDE.md`, `.gitignore` marker via `sync-shared.sh` from core v0.2.0
- Modify: `scripts/test_deploy_files.py`, `scripts/test_docs.py` (expect the new names)
- Create: `docs/vps-cutover.md` (runbook), `docs/superpowers`-style plan file renames: `git mv` any old dated docs in this repo with `warden` in the name
- Modify: `scripts/test_residual_names.py` (enforce `scripts`, `docs`, `all`)

- [ ] **Step 1:** Update `scripts/test_deploy_files.py` and `test_docs.py` expectations and enable `scripts`, `docs`; run `python3 -I -B -m unittest discover -s scripts` → FAIL.
- [ ] **Step 2:** Rename the scripts/workflow/doc content and filenames. Add the "Formerly Warden" line to ADRs and to `vps-setup.md`.
- [ ] **Step 3:** Write `docs/vps-cutover.md`, in order: (1) preconditions (pinned `/healthz` 200 on old install; backup `C:\warden\data` zip); (2) `Stop-Service WardenServer`; (3) `Move-Item C:\warden C:\guardian` (keep `data\tls`, token store); (4) `nssm remove WardenServer confirm`, install `GuardianServer` pointing at `C:\guardian\bin\guardian-server.exe` with `GUARDIAN_*` environment set, no `WARDEN_*` left; (5) firewall: delete old rules by `Name`, add new; (6) create `guardian-deploy` user and authorized key, move `VPS_USER`/`VPS_SSH_KEY` environment secrets accordingly in GitHub, remove `warden-deploy`; (7) copy the new `scripts/` to `C:\guardian\scripts` by hand; (8) start, wait ~15 s, check pinned `/healthz`, wrong pin refused, token `GET /api/v1/policy` with the existing token, admin panel; (9) **manual rollback**: stop `GuardianServer`, move `C:\guardian` back, reinstall `WardenServer` from the v0.1.1 install script, firewall rules, start; (10) cleanup after one stable day: delete backup and `warden-deploy`.
- [ ] **Step 4:** Verify unittest, residual `all` (allow-list: `docs/vps-cutover.md`, ADR/doc "Formerly Warden" notes, rollback section text) → PASS. `scripts/lint.sh` clean. Commit `refactor: rename deployment scripts, workflows and docs to Guardian`; PR; ask before merge.

### Task 8: VPS cutover and server release (owner gate)

- [ ] **Step 1:** Owner follows `docs/vps-cutover.md` steps 1–8 with the new binary built locally or from the release build; pastes outputs. Claude reviews outputs, never sees secrets.
- [ ] **Step 2:** Only after step 8 passes: release PR `develop → main`, owner pushes tag `v0.2.0`, approves the `production` environment, checks the deploy and `/healthz`.
- [ ] **Step 3:** Record the result in `docs/vps-setup.md` (a short "Verified live" note, as in HANDOFF).

---

## Phase 4 — guardian-macos

Working dir: `guardian-macos`. Needs core v0.2.0. Python tests run by `scripts/lint.sh`/CI `unittest discover -s scripts`; create `scripts/test_residual_names.py` (groups `submodule`, `docs`, `swift`, `identity`, `scripts`, `all`).

### Task 9: Docs and display strings

**Files:**
- Modify (git mv + text): `docs/superpowers/specs/2026-10-20-warden-design.md` → `…-guardian-design.md`; `docs/superpowers/plans/2026-10-2*-warden-0{1,2,3,4}-*.md` → `…-guardian-0N-…`; ADR 0001–0003, `docs/e2e-checklist.md`, `docs/vm-setup.md`, `README.md`, `CLAUDE.md` (design path), Info.plist usage strings (`DlpExtension/Info.plist:22`, `Project.swift:42`) — user-visible strings only; identifiers wait for Tasks 10–11
- Create: `scripts/test_residual_names.py`
- Modify: `scripts/lint.sh` or CI to run it if `unittest discover -s scripts` is not already run (CI line 48 runs it)

- [ ] **Step 1:** Create the residual test; enforce `docs`; also a test `test_cross_references_resolve` that every relative markdown link and every `docs/…` path mentioned in `CLAUDE.md`/`README.md` exists. Run → FAIL.
- [ ] **Step 2:** Rename files with `git mv`, update text, add `> Formerly Warden.` under each title (spec, plans, ADRs), update cross-references (also in the spec/plan of this rename, which may keep old-name mentions via `ALLOW`).
- [ ] **Step 3:** `scripts/lint.sh`, `python3 -I -B -m unittest discover -s scripts` → PASS. Commit `docs: rename Warden to Guardian in documentation`; PR; ask before merge.

### Task 10: Swift code, targets, schemes, scripts, GD prefix, submodule bump

**Files:**
- Modify: `Project.swift` (project `Guardian`; targets `GuardianApp`, `GuardianAppTests`, `GuardianCoreLib`; schemes; `coreLib` path `build/corecpp/libguardian_core.a`; header path `external/guardian-core/include`), `git mv WardenApp GuardianApp` and all `Warden*.swift` file/type renames (`WardenApp`, `WardenXPC`, `WardenClientXPC`, `WardenExtensionXPC`, `WardenExtensionReplyXPC`, `WardenXPCError`, test files), `WDButton` and other `WD*` → `GD*`, `CoreBridge/**` and `DlpExtension/**` C++ interop (`warden::` → `guardian::`, includes), `.gitmodules` + `git mv external/warden-core external/guardian-core` at `v0.2.0`, `.swiftlint.yml`, `scripts/*` (`build.sh`, `test.sh`, `coverage.sh`, `sign.sh`, `build-corecpp.sh`, `tokens.py`, `test_tokens.py`), `.github/workflows/ci.yml`, `GuardianApp/GuardianApp.entitlements` filename
- Owner hand edit: `tooling/claude/guard.py`, `test_guard.py` as in Task 2 (or run `tooling/sync-shared.sh` from core v0.2.0, then review the diff)

**Interfaces:**
- Produces: Tuist workspace `Guardian.xcworkspace`; schemes `GuardianApp`, `GuardianAppTests`, `CoreBridgeTests`, `DlpExtensionTests`; XPC protocols `GuardianClientXPC`, `GuardianExtensionXPC`, `GuardianExtensionReplyXPC`, error type `GuardianXPCError` (members unchanged); bundle ids are NOT changed in this task (Task 11).

- [ ] **Step 1:** Enable `submodule`, `swift`, `scripts`; run the residual test → FAIL.
- [ ] **Step 2:** Rename the test targets' sources first (`GuardianApp/Tests/**` types, imports of `@testable import GuardianApp`), `mise exec -- tuist generate` then `scripts/test.sh` → FAIL (production names missing).
- [ ] **Step 3:** Rename production sources, Tuist manifest, schemes, scripts, submodule; regenerate (`Warden.xcworkspace` is generated and ignored — remove the stale one) and regenerate tokens with `python3 -I -B scripts/tokens.py`.
- [ ] **Step 4:** Verify `scripts/build.sh`, `scripts/test.sh`, `scripts/coverage.sh` (≥ 80 %), `scripts/lint.sh`, `python3 -I -B scripts/tokens.py --check`, `python3 -I -B -m unittest discover -s scripts` → PASS. Commit `refactor: rename Swift targets and types to Guardian`; PR; ask before merge.

### Task 11: Identity — bundle ids, Mach service, XPC names, data paths

**Files:**
- Modify: `Project.swift:4-5` (`appID = "io.github.eugenehil.guardian"`, `extID = "io.github.eugenehil.guardian.ext"`), `GuardianApp/GuardianApp.entitlements`, `DlpExtension/DlpExtension.entitlements`, `DlpExtension/Info.plist` (`NSEndpointSecurityMachServiceName`/Mach service name derived from the ext id), `Shared/BundleIDs.swift` equivalents, `DlpExtension/Sources/ES/main.swift:25` (`/Library/Application Support/Guardian/policy.json`), Keychain service name, UserDefaults keys, `PendingEventStore` directory, docs `docs/vm-setup.md`, `docs/e2e-checklist.md`
- Test: `GuardianApp/Tests/BundleIDsTests.swift`, `AppInfoPlistTests.swift`, `ExtensionLinkTests.swift`, Keychain/store tests

- [ ] **Step 1:** Update the tests first: `BundleIDsTests` expects `io.github.eugenehil.guardian` and `.ext`; `AppInfoPlistTests` expects the Mach service name `io.github.eugenehil.guardian.ext` (check the existing assertion shape); a test that the policy file path is `/Library/Application Support/Guardian/policy.json`. Enable `identity`; run `scripts/test.sh` and the residual test → FAIL.
- [ ] **Step 2:** Change the identifiers listed above; grep for any literal of the old bundle id outside tests (should be none).
- [ ] **Step 3:** Verify `scripts/build.sh`, `scripts/test.sh`, `scripts/coverage.sh`, `scripts/lint.sh`, residual `all` (allow-list: this rename's spec and plan, "Formerly Warden" notes, `docs/e2e-checklist.md` migration rows) → PASS. Check with `codesign -d --entitlements :-` on the built app that the application-identifier-related entitlement and `NSEndpointSecurityMachServiceName` carry the new ids.
- [ ] **Step 4:** Commit `refactor: switch bundle ids and data paths to Guardian`; PR; ask before merge. This PR is separate so it can be reverted alone.

### Task 12: VM acceptance and macos release (owner gate)

- [ ] **Step 1:** In the VM remove the old install (`systemextensionsctl list` must show no `…warden…` entries after removal and reboot if required; delete `/Library/Application Support/Warden` and `~/Library/Application Support/io.github.eugenehil.warden`).
- [ ] **Step 2:** Install the new build, approve in System Settings, enter server URL, pin and the existing token. Expected: `Protection active`, `Policy v… · synced`.
- [ ] **Step 3:** Re-run the e2e checklist items that touch identity (install/approve, XPC connect, policy sync, a blocked access producing an event visible in the server panel, quit flush). Record a row in section 8 of `docs/e2e-checklist.md` (PR if needed).
- [ ] **Step 4:** After the owner agrees: release PR `develop → main`, owner pushes `v0.2.0`.

---

## Phase 5 — finish

### Task 13: Workspace files and cleanup (owner assisted)

- [ ] **Step 1:** Edit by hand (no PR; outside git): `/Users/eugene/Mine/git/guardian/HANDOFF.md` (new names, record that the rename is done and where the old-name history lives), `/Users/eugene/Mine/git/guardian/README.md`, `Brewfile` if it names anything.
- [ ] **Step 2:** Delete leftover remote branches named in HANDOFF plus this work's merged branches (owner confirms the list).
- [ ] **Step 3:** Final proof in each repo: `git ls-files | xargs grep -I -i -l -e warden` shows only allow-listed files; CI green on `develop`; pinned `/healthz` 200.

---

## Self-review notes

- Spec coverage: name map (Tasks 2–3, 5–7, 9–11), deploy sequencing (Tasks 7–8), cutover and rollback (Tasks 7–8), VM acceptance (Task 12), keep-list `wdn_`/pin/address (no task touches them; residual pattern excludes `wdn_`), residual check (every phase), "formerly Warden" notes (Tasks 2, 7, 9), gitignore marker (Task 2), guard text (Tasks 2, 7, 10).
- The `all` group's allow-list is the single place where leftover old names are permitted; each task that adds to it says why.
