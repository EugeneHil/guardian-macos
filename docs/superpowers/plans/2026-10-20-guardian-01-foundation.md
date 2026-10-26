# Guardian Foundation Implementation Plan (Plan 1 of 4)

> Formerly Warden.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the three public GitHub repositories with enforced rules (branching, no secrets, Conventional Commits, Claude Code guard hooks), the developer toolchain, and a macOS VM in which an ad‑hoc signed Endpoint Security system extension is proven to activate.

**Architecture:** Shared tooling (guard hook, pre-commit config, PR template, ruleset JSON, bootstrap scripts) is authored once in `guardian-core/tooling/` and copied into the other repos by a sync script. Repos live side by side in `/Users/eugene/Mine/git/guardian/`. The ES spike is throwaway code on an unmerged branch; its outcome is recorded as ADR‑0001.

**Tech Stack:** Homebrew, mise (Tuist pin), gh CLI, git, pre-commit, gitleaks, conventional-pre-commit, Python 3 stdlib (guard hook + tests), GitHub rulesets API, UTM (macOS guest), Xcode 27.

**Spec:** `docs/superpowers/specs/2026-10-20-guardian-design.md` (moved into `guardian-macos/docs/superpowers/specs/` in Task 3)

**Plan series:** 1 Foundation (this) → 2 guardian-core → 3 guardian-server → 4 guardian-macos. Plans 3 and 4 may run in parallel after Plan 2.

## Global Constraints

- Repositories: `guardian-core`, `guardian-macos`, `guardian-server`; GitHub, **public**; Bitbucket unused.
- Branches: `main`, `develop`; default branch `develop`; work branches `feature/WRD-<n>-<slug>`, `fix/…`, `chore/…`, `spike/…`; PRs target `develop`; releases `develop → main` + tag `vX.Y.Z`.
- `main`/`develop`: PR only, required status checks green, linear history, no force push, no deletion.
- Commits: Conventional Commits; never `--no-verify`.
- Secrets never committed: `.env*` (except `.env.example`), `*.pem`, `*.key`, `*.p12`, `*.cer`, `config.local.json`. Three layers: pre-commit gitleaks, CI gitleaks, GitHub secret scanning + push protection.
- Documentation in English; chat with the owner in Russian.
- No paid Apple Developer Program; ES work only inside the macOS VM (SIP off, `amfi_get_out_of_my_way=1`, `systemextensionsctl developer on`), never on the host.
- Workspace path has no spaces: `/Users/eugene/Mine/git/guardian/` **[proposed]**.

## Review Focus

1. Guard hook gets a compound shell command (`cd x && git push origin main`) → must block, not only check the first segment. *(Task 2 test `test_blocks_push_in_compound_command`)*
2. Guard hook crashes on malformed/unknown JSON → must fail closed (exit 2 with a message), never silently allow. *(Task 2 test `test_malformed_input_fails_closed`)*
3. `.env.example` / `config.example.json` must stay readable — over‑blocking makes the agent useless. *(Task 2 tests `test_allows_env_example`, `test_allows_config_example`)*
4. Push to protected branch via refspec (`git push origin HEAD:main`, `git push -u origin develop`) → blocked. *(Task 2 test `test_blocks_push_refspec_to_protected`)*
5. Fresh clone without `pre-commit install` → secret still stopped by the CI gitleaks check required by the ruleset. *(Task 4 verification step)*

---

### Task 1: Developer toolchain

**Files:**
- Create: `/Users/eugene/Mine/git/guardian/Brewfile`
- Create: `/Users/eugene/Mine/git/guardian/README.md` (one paragraph: what the folder is, `brew bundle`, links to the three repos)

**Interfaces:**
- Produces: commands on PATH — `gh`, `mise`, `tuist` (via mise), `cmake`, `ninja`, `clang-format`, `clang-tidy` (from `llvm`), `swiftlint`, `swiftformat`, `gitleaks`, `pre-commit`; GitHub auth for `gh`.

- [ ] **Step 1: Write `Brewfile`** with: `brew "gh"`, `brew "mise"`, `brew "cmake"`, `brew "ninja"`, `brew "llvm"`, `brew "swiftlint"`, `brew "swiftformat"`, `brew "gitleaks"`, `brew "pre-commit"`, `cask "utm"`.
- [ ] **Step 2: Install** — Run: `brew bundle --file /Users/eugene/Mine/git/guardian/Brewfile` → Expected: `Homebrew Bundle complete!`
- [ ] **Step 3: Owner authenticates GitHub** — ask the owner to run `! gh auth login` (HTTPS, browser). Verify: `gh auth status` → `Logged in to github.com account <login>`. Record `<login>` — it is the bundle-ID prefix and repo owner for all plans.
- [ ] **Step 4: Verify toolchain** — Run: `for t in gh mise cmake ninja swiftlint swiftformat gitleaks pre-commit; do command -v $t || echo MISSING $t; done; $(brew --prefix llvm)/bin/clang-tidy --version` → Expected: no `MISSING`, clang-tidy prints a version.

### Task 2: Claude Code guard hook (TDD)

**Files:**
- Create: `/Users/eugene/Mine/git/guardian/guardian-core/tooling/claude/guard.py`
- Test: `/Users/eugene/Mine/git/guardian/guardian-core/tooling/claude/test_guard.py`
- Create: `/Users/eugene/Mine/git/guardian/guardian-core/.claude/settings.json`

**Interfaces:**
- Produces: `decide(event: dict, current_branch: str | None) -> str | None` — returns a human-readable block reason, or `None` to allow. `main() -> int` reads the hook JSON from stdin, gets the branch via `git branch --show-current` in `event["cwd"]`, prints the reason to stderr and returns `2` when blocked, `0` otherwise; any exception → reason `"guard error: <exc>"` and `2`.
- Constants: `PROTECTED_BRANCHES = {"main", "develop"}`, `SECRET_GLOBS = [".env", ".env.*", "*.pem", "*.key", "*.p12", "*.cer", "config.local.json"]`, `ALLOWED_NAMES = {".env.example"}` (matched on basename with `fnmatch`).

- [ ] **Step 0:** `mkdir -p /Users/eugene/Mine/git/guardian/guardian-core && cd /Users/eugene/Mine/git/guardian/guardian-core && git init -b develop`

- [ ] **Step 1: Write the failing tests** (`unittest`, event shape = Claude Code PreToolUse JSON):

```python
E = lambda tool, **inp: {"tool_name": tool, "tool_input": inp, "cwd": "/tmp"}
class GuardTests(unittest.TestCase):
    def test_blocks_reading_env(self):            self.assertIsNotNone(decide(E("Read", file_path="/r/api/.env"), "feature/x"))
    def test_blocks_editing_env_local(self):      self.assertIsNotNone(decide(E("Edit", file_path="/r/.env.local"), "feature/x"))
    def test_blocks_writing_pem(self):            self.assertIsNotNone(decide(E("Write", file_path="/r/certs/server.pem"), "feature/x"))
    def test_blocks_config_local(self):           self.assertIsNotNone(decide(E("Read", file_path="/r/config.local.json"), "feature/x"))
    def test_allows_env_example(self):            self.assertIsNone(decide(E("Read", file_path="/r/.env.example"), "feature/x"))
    def test_allows_config_example(self):         self.assertIsNone(decide(E("Read", file_path="/r/config.example.json"), "feature/x"))
    def test_allows_normal_source(self):          self.assertIsNone(decide(E("Edit", file_path="/r/src/Engine.cpp"), "feature/x"))
    def test_blocks_cat_secret_in_bash(self):     self.assertIsNotNone(decide(E("Bash", command="cat ~/.ssh/id.key"), "feature/x"))
    def test_blocks_commit_on_develop(self):      self.assertIsNotNone(decide(E("Bash", command="git commit -m 'x'"), "develop"))
    def test_allows_commit_on_feature(self):      self.assertIsNone(decide(E("Bash", command="git commit -m 'feat: x'"), "feature/WRD-1-x"))
    def test_blocks_plain_push_from_main(self):   self.assertIsNotNone(decide(E("Bash", command="git push"), "main"))
    def test_blocks_push_refspec_to_protected(self):
        for c in ["git push origin HEAD:main", "git push -u origin develop", "git push origin main"]:
            self.assertIsNotNone(decide(E("Bash", command=c), "feature/x"), c)
    def test_allows_push_feature(self):           self.assertIsNone(decide(E("Bash", command="git push -u origin feature/WRD-1-x"), "feature/WRD-1-x"))
    def test_blocks_force_push(self):             self.assertIsNotNone(decide(E("Bash", command="git push --force-with-lease"), "feature/x"))
    def test_blocks_no_verify(self):              self.assertIsNotNone(decide(E("Bash", command="git commit --no-verify -m x"), "feature/x"))
    def test_blocks_push_in_compound_command(self): self.assertIsNotNone(decide(E("Bash", command="cd repo && git push origin main"), "feature/x"))
    def test_unrelated_tool_allowed(self):        self.assertIsNone(decide(E("Grep", pattern="TODO"), "develop"))
    def test_malformed_input_fails_closed(self):  # main() with stdin "not json" returns 2
        ...  # patch sys.stdin with io.StringIO("not json"); assertEqual(main(), 2)
```

- [ ] **Step 2: Run tests to verify they fail** — Run: `python3 -I -m unittest discover -s /Users/eugene/Mine/git/guardian/guardian-core/tooling/claude -v` → Expected: FAIL/ERROR (`decide` not defined).
- [ ] **Step 3: Implement `guard.py`.** Bash commands are split into segments on `&&`, `||`, `;`, `|`, newline; each segment tokenized with `shlex.split` (fallback `str.split` on `ValueError`). A segment is a git command if its first non-`env`/non-assignment token is `git`; subcommand = first token after `git` not starting with `-`. Rules: any token whose basename matches a secret glob (and is not allowed) → block; `--no-verify` in a git segment → block; `commit` while `current_branch in PROTECTED_BRANCHES` → block; `push` with `--force`, `-f` or `--force-with-lease*` → block; `push` with a positional token equal to a protected branch or ending in `:main`/`:develop` → block; `push` with no refspec while on a protected branch → block. File tools `Read|Edit|Write|NotebookEdit` check `tool_input.file_path`/`notebook_path`.
- [ ] **Step 4: Run tests to verify they pass** — same command → Expected: `OK` (18 tests).
- [ ] **Step 5: Write `.claude/settings.json`**: `hooks.PreToolUse = [{"matcher": "Read|Edit|Write|NotebookEdit|Bash", "hooks": [{"type": "command", "command": "python3 -I \"$CLAUDE_PROJECT_DIR/tooling/claude/guard.py\""}]}]`; `permissions.deny = ["Read(**/.env)", "Read(**/.env.*)", "Read(**/*.pem)", "Read(**/*.key)", "Read(**/*.p12)", "Read(**/config.local.json)"]`. (In consumer repos the path becomes `tooling/claude/guard.py` after sync — same relative path.)
- [ ] **Step 6: Stage** — `git add tooling/claude .claude`. No commit yet: there is no remote or base commit; everything from Tasks 2–3 goes into the bootstrap commit (Task 3 Step 5).

### Task 3: Repository scaffolding and GitHub setup

**Files (authored in `guardian-core`, copied to the others by the sync script):**
- Create: `tooling/repo/gitignore.base` — exactly the spec §6 list.
- Create: `tooling/repo/.pre-commit-config.yaml` — hooks: `gitleaks/gitleaks` (`gitleaks`), `compilerla/conventional-pre-commit` (stage `commit-msg`), `pre-commit/pre-commit-hooks` (`check-merge-conflict`, `end-of-file-fixer`, `trailing-whitespace`, `check-added-large-files`). Revs pinned via `pre-commit autoupdate` at creation.
- Create: `tooling/repo/.gitleaks.toml` — `[extend] useDefault = true`; allowlist paths `\.env\.example$`, `config\.example\.json$`.
- Create: `tooling/repo/pull_request_template.md` — sections: Summary, Linked task (`WRD-<n>`), Tests added/changed, Checklist (TDD followed, no secrets, docs/ADR updated).
- Create: `tooling/repo/CLAUDE.base.md` — rules: TDD mandatory; branch naming; PRs to `develop`; Conventional Commits; never `--no-verify`; no secrets (list); no new dependency without an ADR in `docs/adr/`; Swift: Swift Concurrency only (spec §7), no force unwrap / `try!`; docs in English. Repo-specific sections (stack, build/test commands) are appended by Plans 2–4.
- Create: `tooling/github/ruleset-protected.json` — target `branch`, conditions `ref_name.include = ["refs/heads/main", "refs/heads/develop"]`, rules: `deletion`, `non_fast_forward`, `required_linear_history`, `pull_request` (`required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: true`), `required_status_checks` (`strict_required_status_checks_policy: true`, contexts `["gitleaks"]` — Plans 2–4 add their CI check names).
- Create: `tooling/github/workflows/gitleaks.yml` — job id `gitleaks`, on `pull_request` and `push`, `actions/checkout` with `fetch-depth: 0`, then `gitleaks/gitleaks-action` (actions pinned by commit SHA).
- Create: `tooling/github/dependabot.yml` — ecosystem `github-actions` weekly (consumers add `gitsubmodule` in Plans 3–4).
- Create: `tooling/sync-shared.sh <target-repo-dir>` — copies `tooling/claude/`, `.claude/settings.json`, pre-commit and gitleaks configs, PR template to `.github/`, workflows, dependabot; appends `gitignore.base` to `.gitignore` if absent; creates `CLAUDE.md` from the base if absent. Idempotent.
- Create: `tooling/github/bootstrap-repo.sh <name> "<description>"` — `gh repo create <login>/<name> --public --description … --source . --push`; push `develop` and `main`; `gh repo edit --default-branch develop --delete-branch-on-merge --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge`; enable secret scanning + push protection via `gh api -X PATCH repos/<login>/<name>` (`security_and_analysis`); `gh api repos/<login>/<name>/rulesets -X POST --input tooling/github/ruleset-protected.json`.

**Interfaces:**
- Consumes: `guard.py`, `.claude/settings.json` from Task 2; `<login>` from Task 1.
- Produces: three repos at `github.com/<login>/guardian-{core,macos,server}` with `develop` (default) and `main`; local clones in `/Users/eugene/Mine/git/guardian/`; the spec at `guardian-macos/docs/superpowers/specs/2026-10-20-guardian-design.md` and this plan series at `guardian-macos/docs/superpowers/plans/`.

- [ ] **Step 1:** `mkdir -p /Users/eugene/Mine/git/guardian/guardian-{macos,server}`; in each `git init -b develop`; in `guardian-core` create the files above, `.gitignore` from the base, `README.md` (name + one-line purpose + link to the spec in `guardian-macos`), `CLAUDE.md`.
- [ ] **Step 2:** Run `tooling/sync-shared.sh ../guardian-macos` and `../guardian-server`; run it a second time → Expected: `git status` in targets shows no further changes (idempotent).
- [ ] **Step 3:** Copy the spec and all plan files from `~/Downloads/macos security pet/docs/superpowers/` into `guardian-macos/docs/superpowers/`. Add `guardian-macos/docs/adr/0000-record-architecture-decisions.md` (ADR template: Context / Decision / Consequences).
- [ ] **Step 4:** In each repo: `pre-commit install --hook-type pre-commit --hook-type commit-msg`; `pre-commit run --all-files` → Expected: all `Passed`.
- [ ] **Step 5:** Initial commits — `git commit -m "chore: bootstrap repository"` on `develop` (only allowed now: before the remote/ruleset exists; the guard hook blocks this for the agent, so the **owner runs this step** via `!`), `git branch main`.
- [ ] **Step 6:** Run `tooling/github/bootstrap-repo.sh` for each repo (owner confirms before publishing — this creates public repos).
- [ ] **Step 7: Verify** — `gh api repos/<login>/guardian-core/rulesets` → one ruleset with the rules above; `gh repo view <login>/guardian-core --json defaultBranchRef -q .defaultBranchRef.name` → `develop`; `git push origin develop` from the owner's shell → rejected by the ruleset.

### Task 4: Prove the secret guards end-to-end

**Files:** none committed (throwaway branch).

- [ ] **Step 1: Local layer** — in `guardian-core` on `chore/WRD-2-secret-check`: create `leak.txt` with an AWS-style test key `AKIA` + 16 uppercase chars; `git add leak.txt && git commit -m "test: leak"` → Expected: gitleaks hook **fails**, commit aborted.
- [ ] **Step 2: Commit-msg layer** — commit a harmless file with message `wip stuff` → Expected: conventional-pre-commit **fails**.
- [ ] **Step 3: CI layer** (Review Focus 5) — owner commits `leak.txt` with `git -c core.hooksPath=/dev/null commit -m "test: ci leak"` and pushes the branch, opens a PR to `develop` → Expected: GitHub push protection rejects the push **or** the `gitleaks` check fails and the PR cannot be merged. Close the PR, delete the branch.
- [ ] **Step 4:** Record the three outcomes in `guardian-core/tooling/README.md` (section "Secret guards — verified") via PR `chore/WRD-2-secret-guards-doc` → `develop`.

### Task 5: macOS VM for Endpoint Security

**Files:**
- Create: `guardian-macos/docs/vm-setup.md` — the exact steps below as a runbook.

- [ ] **Step 1:** In UTM create a macOS guest from the latest IPSW (Virtualize → macOS), 4 CPU / 8 GB RAM / 64 GB disk; finish Setup Assistant; install Xcode Command Line Tools; take snapshot `clean`.
- [ ] **Step 2:** Boot the guest into Recovery (UTM: start with recovery option); Terminal: `csrutil disable`; reboot.
- [ ] **Step 3:** In the guest: `sudo nvram boot-args="amfi_get_out_of_my_way=1"`; reboot; `systemextensionsctl developer on`.
- [ ] **Step 4: Verify** — `csrutil status` → `disabled`; `nvram boot-args` → contains `amfi_get_out_of_my_way=1`; `systemextensionsctl developer` → `on`. Take snapshot `es-ready`.
- [ ] **Step 5:** Enable shared folder `/Users/eugene/Mine/git/guardian` → guest, so builds from the host can be run in the guest.

### Task 6: Spike — ad-hoc signed ES system extension activates (throwaway)

Spike rules: no tests, not merged; lives on branch `spike/WRD-3-adhoc-sysext` in `guardian-macos`; only the ADR is merged.

**Files:**
- Create (spike branch): `Spike/` — minimal host app (`SpikeApp`, button "Activate" → `OSSystemExtensionRequest.activationRequest`) + system extension target (`SpikeExt`, ES client subscribing to `ES_EVENT_TYPE_AUTH_OPEN`, denies opens of `/tmp/guardian-spike/secret.txt`, allows everything else with `cache=true`).
- Create (merged via PR): `guardian-macos/docs/adr/0001-adhoc-signed-es-extension.md`

- [ ] **Step 1:** Build both targets with ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), extension entitlements `com.apple.developer.endpoint-security.client = true`, app entitlement `com.apple.developer.system-extension.install = true`; extension `Info.plist` has `NSEndpointSecurityMachServiceName`.
- [ ] **Step 2:** In the VM: copy `SpikeApp.app` to `/Applications`, launch, press Activate, approve in System Settings → General → Login Items & Extensions; grant the extension **Full Disk Access** (required for ES clients).
- [ ] **Step 3: Verify** — `systemextensionsctl list` → extension `[activated enabled]`; `cat /tmp/guardian-spike/secret.txt` → `Operation not permitted`; `cat /tmp/guardian-spike/other.txt` → content printed; `sudo kill -9 <ext pid>` → `cat secret.txt` succeeds until sysextd restarts the extension, then is denied again.
- [ ] **Step 4:** Write ADR‑0001: what worked (exact entitlements, signing flags, approval steps, FDA requirement), what failed and workarounds, measured restart time after `kill -9`. If activation is impossible ad-hoc, the ADR states it and the owner is told immediately — the fallback is buying the Apple Developer Program (owner decision).
- [ ] **Step 5:** PR `docs: ADR-0001 ad-hoc signed ES extension` from `docs/WRD-3-adr-0001` → `develop` (spike branch pushed but not merged).

---

## Self-review notes
- Spec §5 (repos, branches, protection, Conventional Commits, PR template), §6 (three secret layers, hook, `.gitignore`), §3 (VM, SIP, AMFI, spike first), §7 (CLAUDE.md, ADRs, Swift Concurrency rule in CLAUDE.base.md), §8 (Dependabot, gitleaks in CI) — covered. CODEOWNERS is not added: with a single owner and 0 required reviews it enforces nothing **[proposed: omit until a second contributor exists]**.
- Repo-specific CI, coverage gates, linters and CLAUDE.md build sections belong to Plans 2–4.
