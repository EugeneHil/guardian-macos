# Rename Warden to Guardian — design

Date: 2026-10-26. Status: draft for owner approval.

## Intent

The project (a lightweight endpoint DLP for macOS with a Windows server) is renamed from **Warden** to
**Guardian**: a guard, not a jailer. The rename is applied everywhere (full rename, not only the display
name), across `warden-core`, `warden-macos` and `warden-server`, so that after it nothing user-visible,
installed or built is called Warden. History (commits, tags, old release notes) is not rewritten.

## Goals

- Every identifier, path, file name, doc and UI string uses the new name: `Guardian` (types, display),
  `guardian` (namespaces, paths, repo names), `GUARDIAN_` (env vars, CMake options), `GRD` / `grd` (short forms).
- The three GitHub repos become `guardian-core`, `guardian-macos`, `guardian-server`.
- The deployed server keeps working with the same address, TLS certificate, SPKI pin and issued agent token.
- Each step is a small reviewed PR; CI stays green at every merge.

## Non-goals

- No behaviour changes, no new features, no policy or API contract changes.
- No rewriting of git history, no deleting old tags or releases.
- No compatibility layer for the old names (see decisions).

## Anti-goals (failure even if it builds)

- The token, SPKI pin, server address or certificate change or leak into a repo or chat.
- The server is down longer than the planned cutover window, or cannot be rolled back.
- Two names coexist after the work is finished (leftover `Warden` strings in code, docs, CI or UI).
- A stale submodule pins a `warden` namespace while the consumer expects `guardian`.

## Decisions (owner, 2026-10-26)

1. New ticket prefix is `GRD-<n>` (branches `feature/GRD-<n>-<slug>`); existing `WRD-*` stay in history.
2. Server configuration is a hard cut: `WARDEN_*` env vars become `GUARDIAN_*` with no fallback to the old names.
3. The `WD` design-system prefix (`WDButton`, ...) becomes `GD`.
4. Old dated docs are renamed too (`…-warden-0N-….md`, `…-warden-design.md`).
5. The three GitHub repos are renamed first (owner, in GitHub settings), so every PR writes final URLs.
6. Kept as is (HANDOFF): the token prefix `wdn_`, the server address, the SPKI pin, the certificate.

## Name map

| Old | New |
|---|---|
| repos `warden-core`, `warden-macos`, `warden-server` | `guardian-core`, `guardian-macos`, `guardian-server` |
| submodule `external/warden-core` | `external/guardian-core` |
| C++ namespaces `warden`, `warden::server`; headers `include/warden/` | `guardian`, `guardian::server`; `include/guardian/` |
| CMake `warden_core`, `warden_tests`, `warden_alloc_tests`, `warden_warnings`, `warden_server_lib`, `WARDEN_BUILD_TESTS`, `WARDEN_SERVER_*`, `WARDEN_CORE_VERSION` | `guardian_*`, `GUARDIAN_*` |
| Swift `WardenApp`, `WardenAppTests`, `WardenCoreLib`, project `Warden`, `Warden.xcworkspace`, `Warden*XPC*`, `WardenXPCError` | `Guardian*` equivalents |
| `WD*` design-system types | `GD*` |
| bundle ids `io.github.eugenehil.warden`, `.ext` | `io.github.eugenehil.guardian`, `.ext` |
| `/Library/Application Support/Warden/policy.json` | `/Library/Application Support/Guardian/policy.json` |
| `WardenServer` service, `warden-server.exe`, `C:\warden\…` | `GuardianServer`, `guardian-server.exe`, `C:\guardian\…` |
| `warden-deploy` user and key, firewall rule names, `Stop/Start-WardenService`, `WardenLoopbackProbe` | `guardian-deploy`, `Guardian…` |
| `WARDEN_PORT/HOST/DATA_DIR/ADMIN_PASSWORD/TLS_CERT/TLS_KEY/CONFIG_FILE/WEB_ROOT/KEY_FILE` | `GUARDIAN_…` |
| HTTP header `X-Warden-Request` | `X-Guardian-Request` (admin API and panel only; the agent does not send it) |
| test hosts `warden.test`, `warden.example.com` | `guardian.test`, `guardian.example.com` |
| guard hook text, `/r/warden-*` test paths, tooling scripts and README | updated in all three copies |

Old docs: file names are renamed with `git mv`; the text is updated to the new names, and each of the spec,
plans and ADRs gets a one-line note "formerly Warden" under its title. Historical statements about commits,
tags and PR numbers stay as written.

## Constraints

- Branches never target `main`/`develop` directly; PRs go to `develop`; Conventional Commits; TDD (a rename is
  driven by existing tests: rename the test side first, watch it fail, then the production side).
- Warnings are errors; lint and tests run before every commit. Coverage and tokens "in sync" checks must pass.
- Claude has no VPS access. Every VPS and GitHub-settings step is done by the owner, who pastes results.
  Secrets (token, admin password, SSH keys) never go into chat or files.
- Ask before every merge, ruleset change, VPS step and tag push.
- `warden-core` is a submodule of both consumers: it is released first, then consumers bump the pin.

## Order of work

0. This spec and a plan (`superpowers:writing-plans`) in `guardian-macos` (currently `warden-macos`).
1. **Owner:** rename the three GitHub repos; rename local folders; update remotes; re-point the Claude project.
   Check that rulesets, `protected-release-tags`, the `production` environment and its secrets survived.
2. **core PR-1:** docs, display strings, tooling text (`tooling/`, guard hook text, README).
3. **core PR-2:** namespace, `include/guardian/`, CMake targets and options, design-tokens naming. Release v0.2.0
   (owner pushes the tag).
4. **server PR:** submodule to `guardian-core` v0.2.0 (`.gitmodules` URL and path), namespace, `GUARDIAN_*`,
   service, paths, scripts, workflows, header, docs. Release v0.2.0 only after the VPS runbook exists.
5. **Owner, VPS cutover** by a runbook written in the server PR (`docs/`): stop `WardenServer`, move data to
   `C:\guardian` preserving the TLS files and token store, create `GuardianServer` (NSSM), firewall rules,
   `guardian-deploy` user and key, GitHub environment secrets, copy the scripts by hand, tag, approve the
   deploy, check `/healthz` with the unchanged pin and the issued token. The automatic rollback in
   `apply-update.ps1` cannot cover a path change, so the runbook has a manual rollback.
6. **macos PR-1:** docs and display strings. **PR-2:** Swift types, targets, schemes, workspace, scripts,
   `WD`→`GD`, submodule bump. **PR-3:** bundle ids, Mach service, XPC names, data paths, Info.plist strings. Release v0.2.0.
7. **Owner, VM acceptance:** uninstall the old extension, clean install of the new one, approve in System
   Settings, re-enter server URL, pin and token, rerun the key e2e items.
8. Final: update `HANDOFF.md` and the workspace README; remove leftover remote branches.

PR-2 and PR-3 of macos are separate so the identity change can be reverted alone.

## Verification

- After each PR: lint, unit tests, coverage gate, tokens check, CI green.
- Residual check: case-insensitive grep for `warden` and `wdn` (except `wdn_`) in tracked files of each repo
  must return only an explicit allow-list (this spec, "formerly Warden" notes, historical commit references,
  the token prefix `wdn_`). Old `WRD-<n>` ticket ids are historical and are not checked. The allow-list lives in
  a test in each repo.
- After VPS cutover: pinned `/healthz` 200, wrong pin refused, token GET `/api/v1/policy` with `ETag`,
  admin panel loads, service stop/start clean.
- After VM acceptance: app shows `Protection active`, policy synced, a blocked access produces an event on the server.

## Known consequences for installed copies

- An extension with a new bundle id is a different extension: the old one must be removed, the new one approved again.
- The Keychain item and UserDefaults live under the bundle id, so the token and settings are entered again.
- Old data under `Application Support/<old bundle id>` and `/Library/Application Support/Warden` stay on disk; the
  runbook says how to delete them.

## Deploy sequencing

`deploy.yml` runs only on a pushed `v*` tag or a manual dispatch; a merge to `develop` never deploys. So:
(a) the server PR merges with no deploy and the old `WardenServer` keeps running untouched on `C:\warden`;
(b) the owner performs the VPS cutover from the runbook; (c) only then the owner pushes `v0.2.0`, and the first
deploy lands on the already-migrated paths. A tag pushed before (b) would fail its health check and roll back
to the old install, so the plan makes the tag an explicit owner gate after (b).

## Calls made by the author

- The server token store and data files do not depend on the product name (no salt, HMAC context or file name
  derived from it in `src/`; only env vars, the Basic realm, the admin header, CLI texts and version macros
  carry the name). Moving the data directory therefore keeps issued tokens valid. The plan still verifies this
  with a test that loads a token store created under the old layout.
- `Basic realm="Warden"` becomes `Basic realm="Guardian"`.
- The shared `.gitignore` marker (`# --- warden shared ignores`) is renamed to `guardian`; `sync-shared.sh`
  recognizes both the old and the new marker once, so already-synced repos get their block replaced instead of a
  duplicate appended. The old marker is dropped from the script after all three repos are migrated.
- The "Blocked by warden guard" text is not asserted in any test; it is renamed in all three guard copies. The
  guard copies are updated by hand in each repo's own PR (each repo's active hook keeps working between
  PRs because the hook logic does not change, only a message string).
- The workspace root (`/Users/eugene/Mine/git/warden/`) is not a git repository: `HANDOFF.md`, `README.md` are
  edited by hand without a PR. The residual check covers only the three repos. Renaming the root folder to
  `guardian` is the owner's step 1 together with the repo folders.

## Owner answers after the builder check

- Downtime during the VPS cutover is acceptable (tens of minutes): the runbook is stop, move, start, with a manual
  rollback that restores `C:\warden` and `WardenServer`. No side-by-side services.
- The only installed agent is the owner's VM, so no coordinated rollout and no migration of old Keychain,
  UserDefaults or data is needed; the VM is reinstalled clean.

## Left to the builder

- Exact PR slicing inside each phase, and the order of files within a PR.
- Whether the residual-check allow-list lives in a Python test or a shell script (follow each repo's existing style).
- Naming of new internal helpers, if any are needed at all.
