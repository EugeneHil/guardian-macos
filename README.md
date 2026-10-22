# warden-macos

macOS agent of **Warden**, a lightweight Endpoint DLP: a menu bar app (WardenApp), an Endpoint Security system extension (DlpExtension) and an Objective‑C++ bridge (CoreBridge) to the shared C++17 rule engine from [warden-core](../warden-core).

- Design: [docs/superpowers/specs/2026-10-20-warden-design.md](docs/superpowers/specs/2026-10-20-warden-design.md)
- Plans: [docs/superpowers/plans/](docs/superpowers/plans/)
- Decisions: [docs/adr/](docs/adr/)

## Build, test, lint

Requires Xcode 27 and [mise](https://mise.jdx.dev) (pins Tuist), plus `swiftlint` and `swiftformat` (Homebrew).

```sh
mise install            # Tuist 4.212.0
scripts/build.sh        # tuist generate, unsigned xcodebuild into build/, then ad-hoc sign (ADR-0001)
scripts/test.sh         # unit tests for DlpExtensionTests and WardenAppTests (--coverage adds coverage)
scripts/coverage.sh     # tests with coverage, then the >= 80 % line gate (scripts/coverage_gate.py)
scripts/lint.sh         # swiftlint --strict and swiftformat --lint
```

The Endpoint Security extension runs only in the VM described in ADR-0001; it is ad-hoc signed.
