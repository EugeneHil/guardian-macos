# Warden macOS: end-to-end checklist

Run in the macOS VM described in [vm-setup.md](vm-setup.md), once per release. Check each box and fill the result table at the end.

**Secrets:** the server URL, SPKI pin and agent token come from the owner's password manager. Never write them into this file, a commit or a log. Below they appear as `<SERVER_URL>`, `<SPKI_PIN>` and `<TOKEN>`.

## 1. VM preparation

- [ ] Roll the guest back to snapshot `es-ready` (see vm-setup.md). Expected: `csrutil status` says disabled, `nvram boot-args` shows `amfi_get_out_of_my_way=1`, `systemextensionsctl developer` prints `Developer mode: on`.
- [ ] The guest has at least 2 vCPU (design section 7).

## 2. Build and sign

- [ ] On the host: `scripts/build.sh`. Expected: build succeeds, extension and app are ad-hoc signed (`codesign -dv build/Build/Products/Debug/WardenApp.app` shows `Signature=adhoc`).
- [ ] Copy `WardenApp.app` into the guest's `/Applications` (VirtioFS shared directory). Expected: the app launches and shows the menu bar icon.

## 3. Activate

- [ ] In the app, install the extension. Expected: System Settings asks for approval.
- [ ] Approve in System Settings, Login Items & Extensions, Endpoint Security Extensions.
- [ ] Grant Full Disk Access per [vm-setup.md](vm-setup.md). Whether the app (as opposed to the extension) strictly needs it is confirmed in ADR-0001 after the VM run.
- [ ] `systemextensionsctl list`. Expected: the Warden extension shows `[activated enabled]`.

## 4. Settings

- [ ] Open Settings, enter `<SERVER_URL>`, `<SPKI_PIN>` and `<TOKEN>` from the password manager, Save. Expected: no validation errors, sync starts.
- [ ] The menu bar popover shows a connected state and the current policy version.

## 5. Acceptance scenario (design section 9)

- [ ] Step 1. **Panel on VPS:** draft policy with the rule "`.env` and `~/.ssh` are blocked for browsers and AI apps"; validation green; "Publish v2".
  Expected: the panel shows v2 as published.
- [ ] Step 2. **Mac:** within ≤ 15 s (or immediately via "Sync now") the menu bar shows "Policy v2".
  Expected: `Policy v2` within 15 s.
- [ ] Step 3. **Browser:** drag `~/proj/api/.env` into ChatGPT/Claude in Chrome → denied; notification shown; event visible in the popover and in the server panel. `cat ~/proj/api/.env` in Terminal → succeeds (not blocklisted).
  Expected: upload denied, block notification, popover event, panel event; `cat` prints the file.
- [ ] Step 4. **Live policy change:** `python3 -c "open('/Users/…/.ssh/id_ed25519').read()"` succeeds → in the panel add `python3` to the blocklist, publish v3 → after sync the same command fails with `PermissionError`.
  Expected: the first run succeeds; after "Policy v3" it raises `PermissionError`.
- [ ] Step 5. **Failure:** `sudo kill -9 <extension pid>` → the system keeps working with no hangs; sysextd restarts the extension; it restores policy v3 from cache.
  Expected: no hang, the extension runs again within seconds, the python3 command still raises `PermissionError`, the app shows v3 (also with the server stopped).
- [ ] Step 6. **Code walkthrough:** Tuist module graph, green CI in all three repos, README with diagram and roadmap.
  Expected: `tuist graph` renders, CI is green in warden-macos, warden-core and warden-server, README has the diagram and roadmap.

## 6. Clean install

- [ ] Roll back to `es-ready`, install the build from scratch, repeat sections 3-4 and scenario steps 2-3. Expected: works without leftovers from the previous run (a `[terminated waiting to uninstall on reboot]` entry is harmless, ADR-0001 finding 7).

## 7. Plan 4 VM checks

Extension and Endpoint Security:

- [ ] 1. The client starts, mutes itself and subscribes; its own opens of policy.json and binaries do not appear as events; nothing hangs.
- [ ] 2. Fast path: an ordinary file is allowed (and cached); a protected file is denied (EPERM); it is allowed again after the policy is removed (proves the cache clear).
- [ ] 3. Cache clear race: with cached P1, `kill -9` the extension, push P2 protecting a new path within 1 s, open it with a process that opened it just before. Expected: deny; logs show `es_clear_cache` throttle retries if any.
- [ ] 4. Watchdog under burst: 200 parallel `cat` of protected files from new processes. Expected: no "client terminated for missing deadline" in `log show --predicate 'subsystem == "com.apple.endpointsecurity"'`. Repeat with 1 vCPU and with ≥ 2 vCPU.
- [ ] 5. Record the observed message→deadline values for AUTH_OPEN. Expected: all above the 2 s cap.
- [ ] 6. `responsible_audit_token` is non-zero. The audit-token Security lookup works for a Developer ID app, an ad-hoc binary, an unsigned binary and a platform binary (empty team id); note the lookup latency.
- [ ] 7. Pid reuse: does the pid version change on exec; does `kSecCSDynamicInformation` fail for a dead or reused instance.
- [ ] 8. ES `executable.path` form vs `proc_pidpath` (firmlinks, `/private`). Record it in ADR-0001.
- [ ] 9. `es_new_client` failure without Full Disk Access: fault log, respawn cadence, recovery after the grant.
- [ ] 10. `/Library/Application Support/Warden` is root 0700 and `policy.json` is 0600; leftover `.policy.json.*.tmp` files are removed on start.
- [ ] 11. The NSXPC listener accepts the app and nothing else.
- [ ] 12. `es_set_deadline_miss_mode` reads back FAIL_OPEN on macOS 27. Note: the symbol is absent from older SDKs, so it is resolved at runtime via `dlsym`.
- [ ] 13. Fast-path and deadline measurements: record typical and worst-case response time for a fast-path allow and for a candidate evaluation.
- [ ] 14. With `policy.json` in place, `kill -9` the extension and immediately `cat` the protected file. Expected: denied (cache cleared after the cached policy is installed).
- [ ] 15. `kill -9` the app while events flow. Expected: the extension keeps forwarding; the restarted app receives new events.

XPC and app state:

- [ ] 16. NSXPC app↔extension end to end after the `@objc` reply-block mirror: calls succeed, `proxy as? WardenExtensionReplyXPC` works, and an `invalidPolicy` error arrives with its `userInfo` (validation lines) intact.
- [ ] 17. With the extension uninstalled, app memory and Task count stay flat for about 1 h.
- [ ] 18. A rejected policy arrives as `invalidPolicy`, not `unavailable`: it is not re-pushed every 10 s.
- [ ] 19. `lastPolicyVersion` and "Protection active" are correct after an extension restart (the policy is re-pushed on version mismatch).
- [ ] 20. The UI after a relaunch with the server down shows the cached policy.
- [ ] 21. The Full Disk Access hint appears when the extension is activated but XPC is unreachable, including during the `kill -9` restart. Known: it also shows on policy rejection (carry 29; no distinct state yet).

Server link and secrets:

- [ ] 22. The SPKI pin computed by the app from the live server certificate (`SPKIPin.hash(of:)`) matches `warden-server cert pin` and `curl --pinnedpubkey`; a wrong pin refuses the connection.
- [ ] 23. ATS vs the self-signed certificate: ATS does not exempt a public host and the pinning delegate cannot override it (-1200 / -9802), so the app needs `NSAllowsArbitraryLoads` (ADR-0003); no imported certificate is needed. Verify the connection works against a public self-signed host; note the pin-rejection error shape.
- [ ] 23a. The app connects with the server certificate NOT imported into any keychain.
- [ ] 24. Settings (URL, pin) and the token survive an app restart.
- [ ] 25. Keychain smoke: save the token, rebuild the app with a different signature, read (expect the re-enter hint or a prompt), save again (must recover).
- [ ] 26. After a rebuild the Keychain dialog appears at most once a minute (the token is cached in memory).
- [ ] 27. Event upload: a large batch (500 events with long strings) is split on HTTP 413 and delivered; a single oversized event is dropped without a retry loop.

UI in the LSUIElement (accessory) app:

- [ ] 28. Paste (Cmd-V) works in the token SecureField and in the URL field.
- [ ] 29. The popover closes after opening Settings or All events.
- [ ] 30. The notification authorization prompt appears for the ad-hoc signed accessory app, and block notifications are delivered. Note: live delivery is best effort, some blocks may not notify.

Settings and upload resilience:

- [ ] 31. After the server answers 401 (token rotated), saving Settings resumes both policy sync and event upload without restarting the app.
- [ ] 32. Changing only the server URL or pin in Settings does not require re-entering the token when one is stored.
- [ ] 33. A backlog of 500+ events uploads in several batches and none is lost.

## 8. Results

Filled by the owner for each release. Each row cites the checklist item numbers (section 7 numbering) that passed or failed.

| Date | Build (commit/tag) | Pass/fail | Notes |
|------|--------------------|-----------|-------|
|      |                    |           |       |
