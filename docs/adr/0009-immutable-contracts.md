# ADR-0009: Deploy immutable contracts with no admin roles

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 09. An upgradeable system has a different threat model from an immutable
one: the holder of the upgrade key is a trusted party, and every invariant is conditional on that
party. For a research protocol whose output is a report about mechanism behaviour, that
conditionality would contaminate the results — "the pool absorbed the loss" would mean "the pool
absorbed the loss, assuming nobody upgraded it".

## Decision

No owner, no admin role, no setter, no pauser, no proxy, no upgradeability anywhere in the system.
Every parameter is an immutable constructor argument (`docs/spec.md` §3, §9: "changing any
parameter, strategy, oracle, or address | nobody"). The single exception is the one-shot
`wire(...)` of ADR-0021, which resolves the circular addresses once and can never be called again.
Changing anything means deploying a new system.

## Alternatives considered

- **UUPS proxies.** Needs an upgrade authority; the threat model would grow a class of
  "malicious or compromised upgrader" threats that dominate everything else.
- **A pause guardian for emergencies.** The system already has an automatic, permissionless
  emergency path (shutdown, ADR-0010) that no human decides.

## Consequences

- The threat model has no privileged insider (`docs/threat-model.md` §1).
- Mistakes are not fixable in place; they are fixable only by redeploying, which is acceptable
  because nothing holds real funds.
- Parameter values become deployment-time facts, which is what makes the sweeps reproducible
  (ADR-0013).
