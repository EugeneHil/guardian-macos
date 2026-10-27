# macOS VM for Endpoint Security development

Endpoint Security (ES) clients need a restricted entitlement that Apple grants only to paid developer accounts. Without one, an ad-hoc signed extension runs only on a machine with **SIP disabled** and **AMFI relaxed**. Never do this on the host: all ES work happens inside a throwaway VM.

## 1. Create the guest (UTM)

1. Open UTM → **Create a New Virtual Machine** → **Virtualize** → **macOS 12+**.
2. Use the latest IPSW (UTM downloads it, ~15 GB). Resources: 4 CPU, 8 GB RAM, 64 GB disk.
3. Finish Setup Assistant (local account, no Apple ID needed).
4. Install the Command Line Tools: `xcode-select --install`.
5. Shut down and take the snapshot **`clean`** (UTM: VM menu → *Snapshot*; or duplicate the VM bundle).

## 2. Disable SIP

1. Shut the guest down. In UTM right-click the VM → **Edit** → remove nothing; then start it with **Boot to Recovery** (right-click the VM → *Run in Recovery*, or hold the power button equivalent in UTM).
2. In Recovery choose *Options* → *Terminal* (Utilities menu) and run:

   ```
   csrutil disable
   ```
3. Confirm with the account password when asked, then `reboot`.

## 3. Relax AMFI and enable developer mode for system extensions

In the guest, in Terminal:

```
sudo nvram boot-args="amfi_get_out_of_my_way=1"
sudo reboot
systemextensionsctl developer on
```

## 4. Verify

```
csrutil status                       # → System Integrity Protection status: disabled.
nvram boot-args                      # → boot-args    amfi_get_out_of_my_way=1
systemextensionsctl developer        # → Developer mode: on
```

Then shut down and take the snapshot **`es-ready`**. Roll back to it whenever the guest misbehaves.

## 5. Share the workspace

UTM → VM → **Edit → Sharing** → set the shared directory to `/Users/eugene/Mine/git/guardian` (VirtioFS). In the guest it appears in Finder under *Shared Directory*. Build on the host, copy the `.app` into the guest's `/Applications`, run there.

## 6. Reinstall from a build with a previous bundle id

The extension's bundle id is its identity: a build with a different bundle id is a different extension, and the old
one is not replaced. The Keychain item, the app's settings and its data live under the bundle id, so they start empty
(enter the token again). Do this once in the guest, before the first run of a build with a new bundle id:

1. Open the old app and deactivate its extension (or remove it from System Settings → General → Login Items &
   Extensions), then delete the old app from `/Applications` and reboot the guest.
2. `systemextensionsctl list` must show no entry with the previous bundle id. An entry such as "terminated waiting to
   uninstall on reboot" means the reboot has not happened yet.
3. Delete what the previous build left on disk. `<old id>` below is the previous bundle id: the name of the old
   `.app`'s `CFBundleIdentifier`, or whatever the first listing shows. Each command is separate because zsh aborts a
   line when one of its globs matches nothing.
   - Find the old data: `ls -d ~/Library/Application\ Support/io.github.eugenehil.*`
     and `ls -d ~/Library/Preferences/io.github.eugenehil.*`
     and `ls -d /Library/Application\ Support/*/policy.json` (the new `Guardian` directory is created at step 4,
     so only the previous build's directory is listed now).
   - Remove them: `rm -r ~/Library/Application\ Support/<old id>`, `rm ~/Library/Preferences/<old id>.plist`,
     and `sudo rm -r` on the directory that holds the old `policy.json`.
   - Check, then delete the old Keychain item with the stale token (never add `-w` or `-g`, they print the secret):
     `security find-generic-password -s '<old id>.agent-token'`, then
     `security delete-generic-password -s '<old id>.agent-token'`.
4. Open the new app from `/Applications`, approve the extension again, and enter the token. Now
   `systemextensionsctl list` must show only `io.github.eugenehil.guardian.ext` as `[activated enabled]`.

## Notes

- ES clients also need **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add the host app (the system extension inherits it via the app's request flow on activation). In the acceptance VM (SIP disabled, `amfi_get_out_of_my_way=1`, developer mode) the ES client was created and blocking worked without Full Disk Access for both the app and the extension; this is not verified on a normal configuration, so the grant stays recommended.
- Activating a system extension always requires the user to approve it in System Settings → General → Login Items & Extensions (→ *Endpoint Security Extensions*).
- If `amfi_get_out_of_my_way` is silently ignored on a future macOS release, record it in ADR-0001 and escalate to the owner: the fallback is the paid Apple Developer Program.
