# Warden macOS: end-to-end checklist

Run in the macOS VM described in [vm-setup.md](vm-setup.md), once per release. Check each box and fill the result table at the end.

**Secrets:** the server URL, SPKI pin and agent token come from the owner's password manager. Never write them into this file, a commit or a log. Below they appear as `<SERVER_URL>`, `<SPKI_PIN>` and `<TOKEN>`.

## 1. VM preparation

- [x] Roll the guest back to snapshot `es-ready` (see vm-setup.md). Expected: `csrutil status` says disabled, `nvram boot-args` shows `amfi_get_out_of_my_way=1`, `systemextensionsctl developer` prints `Developer mode: on`.
- [x] The guest has at least 2 vCPU (design section 7).

## 2. Build and sign

- [x] On the host: `scripts/build.sh`. Expected: build succeeds, extension and app are ad-hoc signed (`codesign -dv build/Build/Products/Debug/WardenApp.app` shows `Signature=adhoc`).
- [x] Copy `WardenApp.app` into the guest's `/Applications` (VirtioFS shared directory). Expected: the app launches and shows the menu bar icon.

## 3. Activate

- [x] In the app, install the extension. Expected: System Settings asks for approval.
- [x] Approve in System Settings, Login Items & Extensions, Endpoint Security Extensions.
- [x] Grant Full Disk Access per [vm-setup.md](vm-setup.md). Result: not needed in the acceptance VM for either the app or the extension (ADR-0001, "Verified in Plan 4").
- [x] `systemextensionsctl list`. Expected: the Warden extension shows `[activated enabled]`.

## 4. Settings

- [x] Open Settings, enter `<SERVER_URL>`, `<SPKI_PIN>` and `<TOKEN>` from the password manager, Save. Expected: no validation errors, sync starts.
- [x] The menu bar popover shows a connected state and the current policy version.

## 5. Acceptance scenario (design section 9)

- [x] Step 1. **Panel on VPS:** draft policy with the rule "`.env` and `~/.ssh` are blocked for browsers and AI apps"; validation green; "Publish v2".
  Expected: the panel shows v2 as published.
- [x] Step 2. **Mac:** within ≤ 15 s (or immediately via "Sync now") the menu bar shows "Policy v2".
  Expected: `Policy v2` within 15 s.
- [x] Step 3. **Browser:** drag `~/proj/api/.env` into ChatGPT/Claude in Chrome (verified in Safari with `signingIdPrefix com.apple.Safari`; Chrome not verified) → denied; notification shown; event visible in the popover and in the server panel. `cat ~/proj/api/.env` in Terminal → succeeds (not blocklisted).
  Expected: upload denied, block notification, popover event, panel event; `cat` prints the file.
- [x] Step 4. **Live policy change:** `python3 -c "open('/Users/…/.ssh/id_ed25519').read()"` succeeds → in the panel add `python3` to the blocklist, publish v3 → after sync the same command fails with `PermissionError`.
  Expected: the first run succeeds; after "Policy v3" it raises `PermissionError`.
- [x] Step 5. **Failure:** `sudo kill -9 <extension pid>` → the system keeps working with no hangs; sysextd restarts the extension; it restores policy v3 from cache.
  Expected: no hang, the extension runs again within seconds, the python3 command still raises `PermissionError`, the app shows v3 (also with the server stopped).
- [x] Step 6. **Code walkthrough:** Tuist module graph, green CI in all three repos, README with diagram and roadmap.
  Expected: `tuist graph` renders, CI is green in warden-macos, warden-core and warden-server, README has the diagram and roadmap.

## 6. Clean install

- [x] Roll back to `es-ready`, install the build from scratch, repeat sections 3-4 and scenario steps 2-3. Expected: works without leftovers from the previous run (a `[terminated waiting to uninstall on reboot]` entry is harmless, ADR-0001 finding 7).

## 7. Plan 4 VM checks

Extension and Endpoint Security:

- [x] 1. The client starts, mutes itself and subscribes; its own opens of policy.json and binaries do not appear as events; nothing hangs.
- [x] 2. Fast path: an ordinary file is allowed (and cached); a protected file is denied (EPERM); it is allowed again after the policy is removed (proves the cache clear).
- [ ] 3. Cache clear race: with cached P1, `kill -9` the extension, push P2 protecting a new path within 1 s, open it with a process that opened it just before. Expected: deny; logs show `es_clear_cache` throttle retries if any. **Result:** NOT RUN: needs scripted sub-second timing; the cache clear is covered by items 2 and 14.
- [x] 4. Watchdog under burst: 200 parallel `cat` of protected files from new processes. Expected: no "client terminated for missing deadline" in `log show --predicate 'subsystem == "com.apple.endpointsecurity"'`. Repeat with 1 vCPU and with ≥ 2 vCPU. **Result:** PASS: 200 parallel `cat` of protected files, 0 deadline lines in the endpointsecurity log with 4 vCPU and with 1 vCPU; extension pid unchanged on 4 vCPU.
- [ ] 5. Record the observed message→deadline values for AUTH_OPEN. Expected: all above the 2 s cap. **Result:** NOT RUN: AUTH_OPEN message->deadline values are not instrumented; follow-up: diagnostic logging.
- [ ] 6. `responsible_audit_token` is non-zero. The audit-token Security lookup works for a Developer ID app, an ad-hoc binary, an unsigned binary and a platform binary (empty team id); note the lookup latency. **Result:** NOT RUN.
- [ ] 7. Pid reuse: does the pid version change on exec; does `kSecCSDynamicInformation` fail for a dead or reused instance. **Result:** NOT RUN.
- [x] 8. ES `executable.path` form vs `proc_pidpath` (firmlinks, `/private`). Record it in ADR-0001. **Result:** PASS: see ADR-0001, "Verified in Plan 4".
- [x] 9. `es_new_client` failure without Full Disk Access: fault log, respawn cadence, recovery after the grant. **Result:** PASS (VM-only): `es_new_client` succeeded with Full Disk Access off for both app and extension; no "could not create the Endpoint Security client" fault. Not verified on a normal configuration.
- [x] 10. `/Library/Application Support/Warden` is root 0700 and `policy.json` is 0600; leftover `.policy.json.*.tmp` files are removed on start.
- [x] 11. The NSXPC listener accepts the app and nothing else. **Result:** PASS: peer requirement is the signing identifier only; a probe with a foreign identifier is rejected (4097, no reply), a probe with the app identifier gets a reply. Known v0.1 limitation: ad-hoc signing lets any local process claim the identifier.
- [ ] 12. `es_set_deadline_miss_mode` reads back FAIL_OPEN on macOS 27. Note: the symbol is absent from older SDKs, so it is resolved at runtime via `dlsym`. **Result:** PARTIAL: the call returned 0 on macOS 27.0.1; no read-back API is known, so FAIL_OPEN is not directly observable.
- [ ] 13. Fast-path and deadline measurements: record typical and worst-case response time for a fast-path allow and for a candidate evaluation. **Result:** NOT RUN: not instrumented; follow-up: diagnostic logging.
- [x] 14. With `policy.json` in place, `kill -9` the extension and immediately `cat` the protected file. Expected: denied (cache cleared after the cached policy is installed). **Result:** PASS: also confirms the cache clear.
- [x] 15. `kill -9` the app while events flow. Expected: the extension keeps forwarding; the restarted app receives new events.

XPC and app state:

- [ ] 16. NSXPC app↔extension end to end after the `@objc` reply-block mirror: calls succeed, `proxy as? WardenExtensionReplyXPC` works, and an `invalidPolicy` error arrives with its `userInfo` (validation lines) intact. **Result:** PARTIAL: calls succeed end to end; the `invalidPolicy`-with-`userInfo` half was not run (the server cannot serve an invalid policy).
- [x] 17. With the extension uninstalled, app memory and Task count stay flat for about 1 h. **Result:** PASS (app process only): VM, macOS 27.0.1 arm64, WardenApp without the system extension, one sample per minute, 60 samples over about 59 min. RSS dropped about 5 MB in the first 15 min (startup warm-up) and then stayed flat at about 91 MB (variation up to 16 KB); threads stayed at 7 with one transient sample of 8. Sampled rows: 19:45:07 rss_kb=96208 threads=7; 19:59:08 rss_kb=90928 threads=8; 20:14:09 rss_kb=91008 threads=7; 20:29:10 rss_kb=90992 threads=7; 20:44:11 rss_kb=90992 threads=7. No growth, so no leak was observed in one hour. Scope: the extension was not running, so extension memory is not covered, and the app was idle with no events flowing.
- [ ] 18. A rejected policy arrives as `invalidPolicy`, not `unavailable`: it is not re-pushed every 10 s. **Result:** NOT RUN: the server cannot serve an invalid policy; covered by unit tests (`invalidPolicy` as a reply error, `rejectedETag`).
- [x] 19. `lastPolicyVersion` and "Protection active" are correct after an extension restart (the policy is re-pushed on version mismatch). **Result:** PASS: observed implicitly in acceptance step 5 and section 6 (after an extension restart the app showed the cached version).
- [x] 20. The UI after a relaunch with the server down shows the cached policy. **Result:** PASS: observed implicitly in acceptance step 5 and section 6 (cached version shown with the server stopped).
- [ ] 21. The Full Disk Access hint appears when the extension is activated but XPC is unreachable, including during the `kill -9` restart. Known: it also shows on policy rejection (carry 29; no distinct state yet). **Result:** NOT RUN: Full Disk Access is not needed in this VM, so the hint is not reproducible.

Server link and secrets:

- [x] 22. The SPKI pin computed by the app from the live server certificate (`SPKIPin.hash(of:)`) matches `warden-server cert pin` and `curl --pinnedpubkey`; a wrong pin refuses the connection.
- [x] 23. ATS vs the self-signed certificate: ATS does not exempt a public host and the pinning delegate cannot override it (-1200 / -9802), so the app needs `NSAllowsArbitraryLoads` (ADR-0003); no imported certificate is needed. Verify the connection works against a public self-signed host; note the pin-rejection error shape. **Result:** PASS: fixed by ADR-0003 (`NSAllowsArbitraryLoads`).
- [x] 23a. The app connects with the server certificate NOT imported into any keychain. PASS: verified with the server certificate not imported anywhere.
- [x] 24. Settings (URL, pin) and the token survive an app restart.
- [x] 25. Keychain smoke: save the token, rebuild the app with a different signature, read (expect the re-enter hint or a prompt), save again (must recover). **Result:** PASS: after rebuilding the app the token was read without a dialog and sync continued; the failure-recovery path was not triggered (covered by unit tests).
- [x] 26. After a rebuild the Keychain dialog appears at most once a minute (the token is cached in memory). **Result:** PASS: no dialog or hint in 3 minutes after a rebuild.
- [ ] 27. Event upload: a large batch (500 events with long strings) is split on HTTP 413 and delivered; a single oversized event is dropped without a retry loop. **Result:** NOT RUN: covered by unit tests (`payloadTooLarge`, batch split, single oversized event dropped).

UI in the LSUIElement (accessory) app:

- [x] 28. Paste (Cmd-V) works in the token SecureField and in the URL field.
- [x] 29. The popover closes after opening Settings or All events.
- [x] 30. The notification authorization prompt appears for the ad-hoc signed accessory app, and block notifications are delivered. Note: live delivery is best effort, some blocks may not notify.

Settings and upload resilience:

- [x] 31. After the server answers 401 (token rotated), saving Settings resumes both policy sync and event upload without restarting the app.
- [x] 32. Changing only the server URL or pin in Settings does not require re-entering the token when one is stored.
- [x] 33. A backlog of 500+ events uploads in several batches and none is lost.

## 8. Results

Filled by the owner for each release. Each row cites the checklist item numbers (section 7 numbering) that passed or failed.

| Date | Build (commit/tag) | Pass/fail | Notes |
|------|--------------------|-----------|-------|
| 2026-10-24 | `develop` at e91bb4b plus this docs change | pass with noted gaps | Items 3, 5, 6, 7, 13, 18, 21 and 27 were not run, 12 and 16 are partial, 17 passed for the app process only (see the results in section 7). |
