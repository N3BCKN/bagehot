"""P17-1 evidence: a rough attack-cost model for stake collapse in deployment A.

Analysis only (floats allowed; nothing here is protocol state). Order of magnitude, not a price.

Attack round (spec 6.4.1-6.4.2, 6.5.2-6.5.4, 6.7.3):
  1. open an own position with collateral K (USD) at ICR = MCR; one second of interest takes it
     below MCR;
  2. liquidate it into an empty pool: the pool seizes debt x (1 + penalty) worth of collateral and
     the VaultManager redistributes it, with the debt, to every staked position; the surplus goes
     back to the owner, and the gas reserve to the liquidator (the attacker);
  3. redeem the redistributed debt out of the honest positions (fee: floor + base rate, the base
     rate decayed between rounds), which re-stakes them at the new, lower snapshot ratio.
Each round multiplies the snapshot ratio S/C by about C / (C + seized). The attacker loses the
penalty plus the redemption fee per round; the honest collateral F that redemption cannot remove
(MIN_DEBT floors, owners' own excess collateral) sets the scale.

Young or empty deployment: if the attacker holds every staked position, the penalty and the
redistributed collateral return to the attacker, so the loss is gas only.

Targets: snapshot ratio 1e-15 (a 1-WETH position staked at ~1,000 wei: 0.1 % reward misallocation,
I13 weak) and 1e-20 (positions up to 100 WETH staked at 0: `totalStakes == 0` with open positions,
the DEFICIT path of 6.4.1).

Not modelled: pool deposits that must be burned through first (each refill costs the attacker the
penalty on it), competing liquidators, price moves.

Run: python3 scripts/analysis/stake_collapse_cost.py
"""

import math

MCR, PENALTY, FEE_FLOOR, BETA = 1.10, 0.05, 0.005, 2
MIN_POSITION_USD = 2_200  # MIN_DEBT 2,000 at MCR
GAS_PER_ROUND = 800_000  # open + liquidate + redeem, rough


def honest_attack(F, K, target, debt_frac=0.6, max_rounds=200_000):
    """Rounds and loss (USD) to take the snapshot ratio from 1 to `target`, honest collateral F."""
    ch, dh = F, F * debt_frac / MCR
    r, sh = 1.0, F
    loss, rounds = 0.0, 0
    while r > target and rounds < max_rounds:
        rounds += 1
        d = K / MCR
        seized = min(K, d * (1 + PENALTY))
        ch += seized
        dh += d
        r = sh / ch
        loss += seized - d
        fee = min(FEE_FLOOR + d / ((dh + d) * BETA), 1.0)
        loss += fee * d
        ch -= d
        dh -= d
        sh = ch * r
    return rounds, loss


def cheapest(F, target):
    best = None
    for rho in (0.001, 0.003, 0.01, 0.03, 0.1, 0.3, 1.0, 3.0):
        K = max(rho * F, MIN_POSITION_USD)
        n, loss = honest_attack(F, K, target)
        if best is None or loss < best[1]:
            best = (n, loss, K)
    return best


def young_attack(target, K=100 * MIN_POSITION_USD):
    """Attacker holds every stake: one minimum position P1 plus a recycled position K."""
    return math.ceil(
        math.log(1 / target) / math.log(1 + (1 - PENALTY / MCR) * K / MIN_POSITION_USD)
    ), K


def main():
    targets = ((1e-15, "1,000-wei stakes on 1 WETH"), (1e-20, "zero stakes (DEFICIT path)"))
    print(
        "| honest collateral F | target | liquidations (attacker positions)"
        " | position size | attacker loss | transactions |"
    )
    print("|---|---|---|---|---|---|")
    for target, label in targets:
        n, K = young_attack(target)
        print(
            f"| none (young deployment) | {label} | {n} | ${K:,.0f}, recycled"
            f" | gas only | ~{3 * n} |"
        )
    for F in (1e5, 1e6, 1e7, 1e8):
        for target, label in targets:
            n, loss, K = cheapest(F, target)
            print(
                f"| ${F:,.0f} | {label} | {n:,} | ${K:,.0f}"
                f" | ${loss:,.0f} ({loss / F:.1f}×F) | ~{3 * n:,} |"
            )
    print(
        f"\nGas: ~{GAS_PER_ROUND:,} per round, so 60,000 rounds are"
        f" ~{60_000 * GAS_PER_ROUND / 1e9:.0f}e9 gas."
    )


if __name__ == "__main__":
    main()
