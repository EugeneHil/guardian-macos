# ADR-0000: Record architecture decisions

- Status: accepted
- Date: 2026-10-20

## Context

Warden spans three repositories and several non-obvious platform decisions (Endpoint Security signing, cross-platform C++ core, Swift Concurrency rules). Decisions must be traceable after the fact.

## Decision

Every significant decision — architecture, platform constraint, new dependency — is recorded as a short ADR in `docs/adr/NNNN-<slug>.md` of the repository it affects, using this template: Context / Decision / Consequences. ADRs are immutable once accepted; a later ADR supersedes an earlier one.

## Consequences

New dependencies require an ADR before they are added (see `CLAUDE.md`). Reviewers can reject a PR that changes a recorded decision without a superseding ADR.
