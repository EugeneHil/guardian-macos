# ADR-0001: Ad-hoc signed Endpoint Security extension in a VM

- Status: accepted
- Date: 2026-10-21

## Context

Warden v0.1 is developed without a paid Apple Developer Program membership (design §3). Endpoint Security (ES) clients need the restricted entitlement `com.apple.developer.endpoint-security.client`, which Apple grants only through a provisioning profile. A day-one spike had to prove that an ad-hoc signed ES system extension can be built, activated and can deny file opens, and had to expose the practical pitfalls before the real `DlpExtension` is written.

Environment: macOS 27 guest in UTM (SIP disabled, `amfi_get_out_of_my_way=1`, `systemextensionsctl developer on`), host Xcode 27.0, Tuist 4.212.0. Spike code: branch `spike/WRD-3-adhoc-sysext` (throwaway, not merged).

## Decision

v0.1 proceeds **without** a paid certificate. The ES extension is ad-hoc signed and run only inside the macOS VM described in `docs/vm-setup.md`. No development of ES features happens on the host.

## Findings (observed in the spike)

1. **Xcode refuses to sign.** Even with `CODE_SIGN_IDENTITY="-"`, `xcodebuild` fails with "requires a provisioning profile" for targets carrying the ES / system-extension entitlements. Workaround: build with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`, then sign inside-out with `codesign --force --sign - --entitlements <file>` (extension first, then app). Reference: `Spike/sign.sh`.
2. **The extension bundle must be named after its identifier.** With `SpikeExt.systemextension` the activation failed with `OSSystemExtensionErrorDomain Code=4` ("Extension not found in App bundle"). Renaming the bundle to `dev.warden.spike.ext.systemextension` fixed it. With Tuist: `PRODUCT_NAME = <extension bundle identifier>` on the extension target.
3. **`NSSystemExtensionUsageDescription` is required in the extension's own Info.plist** (not only the app's), otherwise `Code=9`.
4. **Activation then succeeds** (`finished: 0`, no reboot) after the user approves the extension in System Settings → Login Items & Extensions. `systemextensionsctl list` shows `[activated enabled]`.
5. **Deny works and covers writes.** An `AUTH_OPEN` handler answering `es_respond_flags_result(…, 0, false)` for the target file made `cat` fail with `Operation not permitted`, and also made a shell redirect (`>`) onto that file fail. Policy evaluation therefore sees every open regardless of access mode; if read-only protection is ever wanted, the open flags must be inspected.
6. **Restart after `kill -9`:** the extension was running again and denying within about 1 s. The poll step was 0.5 s, so the fail-open window itself was **not observed**; its length is unmeasured.
7. Replaced builds leave a `[terminated waiting to uninstall on reboot]` entry in `systemextensionsctl list` until the guest reboots. Harmless.

## Exact configuration that worked

- Signing: ad-hoc (`codesign --force --sign -`), extension signed first, then the app; no Team ID; `ENABLE_HARDENED_RUNTIME=NO`; `CODE_SIGN_STYLE=Manual`; deployment target macOS 15.0; extension linked with `-lEndpointSecurity`.
- Extension entitlements: `com.apple.developer.endpoint-security.client = true` and `com.apple.security.application-groups = ["dev.warden.spike"]`.
- App entitlement: `com.apple.developer.system-extension.install = true`.
- Extension Info.plist: `CFBundlePackageType = SYSX`, `NSEndpointSecurityMachServiceName = dev.warden.spike.ext`, `NSEndpointSecurityEarlyBoot = false`, `NSSystemExtensionUsageDescription` (see finding 3).
- App Info.plist: `NSSystemExtensionUsageDescription`.
- Bundle identifiers: app `dev.warden.spike`, extension `dev.warden.spike.ext` (the app identifier is a prefix of the extension's).

## Not verified by the spike

- Whether Full Disk Access is strictly required for the extension (it was granted per the runbook; not isolated).
- That ES reports symlink-resolved paths (e.g. `/private/tmp/…` for `/tmp/…`); the spike matched a path suffix. `CoreCpp` must still normalize `/tmp`, `/var`, `/etc` and test it in the VM.
- Behavior on a Mac with SIP enabled — impossible without the paid entitlement; out of scope for v0.1.

## Consequences

- No $99 purchase is needed for v0.1. Anyone cloning the repo can run the agent only in a VM prepared like ours; this limitation goes into the README and the roadmap (paid certificate → notarization → real distribution).
- `DlpExtension` in Plan 4 reuses the sign script approach (finding 1) and the naming/Info.plist rules (findings 2–3).
- The XPC client check can only pin the bundle identifier (no Team ID), as noted in design §3.
- Replacing a running extension requires deactivation/approval cycles in the guest; the e2e checklist must include "clean snapshot → install → verify".

## Verified in Plan 4

To be filled after the VM run (owner). Do not fill with estimates.

- ES `executable.path` form (symlink-resolved or not, `/private` prefix, firmlinks, comparison with `proc_pidpath`): to be filled after the VM run.
- Full Disk Access requirement (is `es_new_client` refused without it, and with what error): to be filled after the VM run.
- Measured fail-open window after `kill -9` of the extension: to be filled after the VM run.
- Observed message->deadline values for AUTH_OPEN (and whether they exceed the 2 s cap): to be filled after the VM run.
- `es_set_deadline_miss_mode` read-back on macOS 27: to be filled after the VM run.
