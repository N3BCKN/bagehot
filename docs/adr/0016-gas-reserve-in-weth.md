# ADR-0016: Pay the gas reserve in WETH; handle no native ETH

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Kit correction 2, and `docs/spec.md` D-5: the blueprint's appendix had `openPosition` as `payable`
with a native-ETH gas reserve. Handling native ETH means a `receive`/fallback, a second asset in
every accounting identity, and transfers that can fail or re-enter through the recipient's
fallback — exactly the class of problem the reentrancy rules exist to avoid.

The reserve's purpose is to pay a liquidator for gas, not to be gas: it is an incentive denominated
in value, and WETH is already the collateral.

## Decision

`GAS_RESERVE` is an amount of WETH, pulled together with the collateral at `openPosition`, which is
**not** `payable` (`docs/spec.md` §5.1.1, D-5). No contract in the system holds, receives or sends
native ETH, and none has a `receive` or payable fallback. The reserve is paid to whoever liquidates
(A) or starts the auction (B), returned on `close` or full redemption, and reclaimable after
settlement (§5.1.10).

## Alternatives considered

- **Native ETH reserve.** Needs payable entry points, a fallback on every recipient path, and a
  second asset in I1; a recipient that reverts on receive could block a liquidation.
- **Reserve in stablecoin.** The borrower would have to hold the token before borrowing it, and
  the reserve would be exposed to the deficit it is meant to be independent of.

## Consequences

- One asset, one set of transfer rules: `SafeERC20` everywhere, no `call{value:}` anywhere.
- The liquidation-cost model (P24) converts gas to WETH at the measured price; the reserve is sized
  from that (ADR-0007).
- A borrower needs WETH for collateral and reserve in one approval.
