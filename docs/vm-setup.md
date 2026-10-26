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

## Notes

- ES clients also need **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add the host app (the system extension inherits it via the app's request flow on activation). In the acceptance VM (SIP disabled, `amfi_get_out_of_my_way=1`, developer mode) the ES client was created and blocking worked without Full Disk Access for both the app and the extension; this is not verified on a normal configuration, so the grant stays recommended.
- Activating a system extension always requires the user to approve it in System Settings → General → Login Items & Extensions (→ *Endpoint Security Extensions*).
- If `amfi_get_out_of_my_way` is silently ignored on a future macOS release, record it in ADR-0001 and escalate to the owner: the fallback is the paid Apple Developer Program.
