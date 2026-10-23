# ADR-0003: App Transport Security disabled for the pinned transport

- Status: accepted
- Date: 2026-10-23

## Context

The agent talks to a user-configured server that presents a self-signed certificate. Trust is decided only by an SPKI pin in `PinnedURLSession`; the system CA store is never consulted. A bundled macOS app has App Transport Security (ATS) enabled. For a public host ATS evaluates system trust, and a `URLSession` delegate answering `.useCredential(URLCredential(trust:))` does not override it. The connection fails with `NSURLErrorDomain` -1200 / -9802 ("ATS failed system trust") even though the pin matches. Bare binaries, loopback and LAN hosts are exempt, which hid the problem in earlier checks.

## Decision

Set `NSAppTransportSecurity` -> `NSAllowsArbitraryLoads = true` in the WardenApp Info.plist (`Project.swift`). The DlpExtension Info.plist is unchanged. `AppInfoPlistTests` fails if the setting is dropped.

## Evidence

Experiment on a public self-signed host, run from an .app bundle:

| Info.plist setting | Result |
| --- | --- |
| default | fails (-1200 / -9802) |
| `NSAllowsLocalNetworking` | fails |
| `NSAllowsArbitraryLoads = true` | passes |
| `NSExceptionDomains` | passes only for a domain name |

The server URL is user-entered and often an IP address, so `NSExceptionDomains` cannot be used.

## Consequences

- ATS is off for the whole app.
- Mitigated by: the only transport is `PinnedURLSession`; Settings validation accepts https only; trust comes solely from the SPKI pin and never falls back to the CA store. This is stricter than ATS.
- A CA-signed server certificate would not need this setting.
- No certificate has to be imported into a keychain.
- Rule: any future non-pinned network use (another `URLSession`, WebKit, third-party SDK) must be reviewed against this ADR before it ships.
