"""CHG-009 evidence: an exact-integer model of spec 6.5.2-6.5.4 and the 6.3.1 list order,
searched for violations of CHG-008's per-member I13 bound and of the hidden-key bound.

Protocol state is integers only, mirroring the Solidity rounding (floors as in R8, R10 and 6.5.2's
carry). Fractions appear only in the hidden-key check (h, iota), which is analysis, not protocol
state. Interest is 0 (index = RAY), so normalised debt equals debt, as in the Foundry regression.

Run: python3 scripts/analysis/i13_bound_search.py
"""

import itertools
import random
from fractions import Fraction as F

DP = 10**18
WAD = 10**18
MIN_DEBT = 2000 * WAD
MCR = 11 * 10**17
PENALTY = 5 * 10**16
PRICE_MIN = 10 * WAD  # OracleAdapter bounds used by the tests


class Sys:
    def __init__(s, validate=False):
        s.L = s.LD = s.eC = s.eD = s.pC = s.pN = 0
        s.T = s.TC = s.S = s.C = 0
        s.m = {}  # id -> [coll, normDebt, stake, snapLColl, snapLDebt]
        s.order = []  # head (highest NICR) first
        s.red = 0
        s.redAt, s.h, s.iota = {}, {}, {}
        s.nextId = 1
        s.validate = validate
        s.worst = 0.0  # largest share of CHG-008's pair tolerance used by an inversion

    def eff(s, i):
        c, n, st, sl, sd = s.m[i]
        return c + st * (s.L - sl) // DP, n + st * (s.LD - sd) // DP

    def precedes(s, a, b):
        ca, na = s.eff(a)
        cb, nb = s.eff(b)
        return ca * nb > cb * na or (ca * nb == cb * na and a < b)

    def stake(s, c):
        return c if s.S == 0 or s.C == 0 else c * s.S // s.C

    def hobs(s, i):
        C, N = s.eff(i)
        return F(N * (DP + s.L), C) - s.LD

    def insert(s, i):
        k = 0
        while k < len(s.order) and s.precedes(s.order[k], i):
            k += 1
        s.order.insert(k, i)
        c, n, st, sl, sd = s.m[i]
        s.h[i] = F(n * (DP + sl), c) - sd
        X = s.order[k - 1] if k > 0 else None
        Y = s.order[k + 1] if k + 1 < len(s.order) else None
        io = F(0)
        if X is not None:
            io = max(io, s.iota[X] + s.h[X] - s.hobs(X))
        if Y is not None:
            io = max(io, s.iota[Y] + s.hobs(Y) - s.h[Y])
        s.iota[i] = io
        s.redAt[i] = s.red

    def apply(s, i):
        c, n, st, sl, sd = s.m[i]
        pc, pn = st * (s.L - sl) // DP, st * (s.LD - sd) // DP
        s.m[i] = [c + pc, n + pn, st, s.L, s.LD]
        s.pC -= pc
        s.pN -= pn
        s.TC += pc

    def open(s, c, n, price=None):
        if s.validate:
            assert n >= MIN_DEBT and c * price >= MCR * n, ("invalid open", c, n, price)
        i = s.nextId
        s.nextId += 1
        st = s.stake(c)
        s.m[i] = [c, n, st, s.L, s.LD]
        s.T += st
        s.TC += c
        s.insert(i)
        return i

    def adjust(s, i, dc, dn):
        s.apply(i)
        s.order.remove(i)
        c, n, st, sl, sd = s.m[i]
        c2, n2 = max(c + dc, 10**6), max(n + dn, 10**6)
        s.TC += c2 - c
        st2 = s.stake(c2)
        s.T += st2 - st
        s.m[i] = [c2, n2, st2, sl, sd]
        s.insert(i)

    def redistribute(s, i, liq_price=None):
        c, n, st, sl, sd = s.m[i]
        if st >= s.T:
            return False
        if s.validate:  # a deployment-A liquidation that returns the whole collateral (6.4.1-6.4.2)
            C, N = s.eff(i)
            assert (
                liq_price >= PRICE_MIN
                and C * liq_price < MCR * N
                and C * liq_price <= (WAD + PENALTY) * N
            )
        s.apply(i)
        s.order.remove(i)
        c, n, st, sl, sd = s.m[i]
        s.T -= st
        s.TC -= c
        del s.m[i]
        cn, nn = c * DP + s.eC, n * DP + s.eD
        dl, dd = cn // s.T, nn // s.T
        s.eC, s.eD = cn - dl * s.T, nn - dd * s.T
        s.L += dl
        s.LD += dd
        s.pC += c
        s.pN += n
        s.S, s.C = s.T, s.TC + s.pC
        s.red += 1
        return True

    def k(s, i, coll):
        c, n, st, sl, sd = s.m[i]
        mm = s.red - s.redAt[i]
        d = (s.L - sl) if coll else (s.LD - sd)
        return 1 + -(-(d + mm + st * mm) // DP)

    def check(s):
        """Returns (CHG-008 violated, hidden-key violated) over the adjacent pairs."""
        old = new = False
        for a, b in zip(s.order, s.order[1:], strict=False):
            ca, na = s.eff(a)
            cb, nb = s.eff(b)
            inv = cb * na - ca * nb
            if inv > 0:
                kca, knb = s.k(a, True), s.k(b, False)
                s.worst = max(s.worst, inv / (kca * nb + ca * knb + kca * knb))
                old |= (ca + kca) * (nb + knb) < cb * na
            new |= s.h[a] - s.iota[a] > s.h[b] + s.iota[b]
        return old, new


def random_family(seed):
    rng = random.Random(seed)
    s, price = Sys(), 2000

    def pos(c, icr):
        return c, c * price * 100 // int(icr * 100)

    for _ in range(rng.choice([3, 8, 20, 40])):
        s.open(*pos(rng.randrange(10**18, 10**19) + rng.randrange(10**6), rng.uniform(1.5, 4)))
    for _ in range(rng.randrange(20, 80)):
        r, ids = rng.random(), list(s.m)
        if r < 0.30 and len(ids) > 2:
            lows = sorted(ids, key=lambda i: s.eff(i)[0] * 10**6 // max(1, s.eff(i)[1]))
            s.redistribute(lows[0] if rng.random() < 0.7 else rng.choice(ids))
        elif r < 0.45:
            icr = rng.uniform(1.1, 1.3) if rng.random() < 0.5 else rng.uniform(2, 4)
            s.open(*pos(rng.choice([10**18, 10**20, 10**21]) + rng.randrange(10**12), icr))
        elif ids:
            i = rng.choice(ids)
            c, n = s.eff(i)
            s.adjust(i, rng.randrange(-c // 3, c // 3), rng.randrange(-n // 3, n // 3))
        yield s


def newcomer_family(seed):
    """A dominant newcomer just behind a member, then debt-heavy remainders (review F3's shape)."""
    rng = random.Random(seed)
    s, price = Sys(), 2000

    def pos(c, icr):
        return c, c * price * 1000 // int(icr * 1000)

    a = s.open(*pos(rng.randrange(10**18, 10**19), rng.uniform(2.5, 3.5)))
    for _ in range(rng.choice([10, 40, 80])):
        s.open(*pos(rng.randrange(10**18, 10**19) + rng.randrange(10**9), rng.uniform(2.0, 4.0)))
    s.redistribute(s.open(*pos(5 * 10**18 + rng.randrange(10**9), 1.15)))
    for _ in range(rng.randrange(50, 800)):
        i = rng.choice([x for x in s.m if x != a])
        c, n = s.eff(i)
        s.adjust(i, rng.randrange(-c // 50, c // 50), rng.randrange(-n // 50, n // 50))
    s.redistribute(s.open(*pos(5 * 10**18 + rng.randrange(10**9), 1.15)))
    ca, na = s.eff(a)
    cb = s.TC * rng.choice([10, 100, 1000]) + rng.randrange(10**12)
    s.open(cb, cb * na // ca + 1)
    for _ in range(rng.randrange(1, 4)):
        d = s.T * s.T // DP * rng.choice([10, 100, 1000, 10000]) + 1
        s.redistribute(s.open(max(1, int(d * rng.choice([0.2, 0.5, 1.0, 1.1])) // price), d))
        yield s


def protocol_valid(P):
    """Every open at >= MCR and >= MIN_DEBT at its price; every remainder a full-collateral
    liquidation at P['price'] // 10. Dust: small remainders, each followed by every member but A
    re-applying."""
    s, pr = Sys(validate=True), P["price"]
    liq = pr // 10

    def coll_for(debt, icr_milli):
        return debt * icr_milli * WAD // (1000 * pr) + 1

    a = s.open(coll_for(3 * MIN_DEBT, 3000), 3 * MIN_DEBT, pr)
    others = [
        s.open(coll_for(MIN_DEBT * (2 + j), 2500 + 100 * j), MIN_DEBT * (2 + j), pr)
        for j in range(P["k"])
    ]
    for r in range(P["rounds"]):
        s.redistribute(s.open(coll_for(MIN_DEBT, P["dustIcr"]), MIN_DEBT, pr), liq)
        for j, i in enumerate(others):
            s.adjust(i, 1 + (r * 7919 + j * 104729) % 10**9, 0)
    s.redistribute(s.open(coll_for(MIN_DEBT, P["dustIcr"]), MIN_DEBT, pr), liq)
    ca, na = s.eff(a)
    cb = ca * P["bMult"] + 12345
    b = s.open(cb, cb * na // ca + 1, pr)
    for _ in range(P["crashes"]):
        d = max(MIN_DEBT, s.T * s.T // DP * P["mult"])
        s.redistribute(s.open(coll_for(d, 1100), d, pr), liq)
        yield s
    s.ids = (a, b)


def run_family(gen_iter):
    """Runs one scenario; returns (CHG-008 violated, hidden-key violated, worst share)."""
    old = new = False
    s = None
    for s in gen_iter:
        o, n = s.check()
        old |= o
        new |= n
    return old, new, (s.worst if s else 0.0)


def main():
    rows = []
    for name, scenarios in (
        ("random", (random_family(seed) for seed in range(2000))),
        ("dominant newcomer, debt-heavy", (newcomer_family(seed) for seed in range(600))),
    ):
        res = [run_family(g) for g in scenarios]
        rows.append(
            (name, len(res), sum(r[0] for r in res), sum(r[1] for r in res), max(r[2] for r in res))
        )
    grid = itertools.product(
        (10**5 * WAD, 10**6 * WAD), (6, 20), (100, 400), (2000, 2600), (10, 1000), (100, 10**4)
    )
    res = []
    for price, k, rounds, dust, bm, mult in grid:
        P = dict(price=price, k=k, rounds=rounds, dustIcr=dust, bMult=bm, mult=mult, crashes=2)
        res.append(run_family(protocol_valid(P)))
    rows.append(
        (
            "protocol-valid deterministic grid",
            len(res),
            sum(r[0] for r in res),
            sum(r[1] for r in res),
            max(r[2] for r in res),
        )
    )

    print(
        "| family | scenarios | CHG-008 violated | hidden-key violated"
        " | largest share of CHG-008's tolerance used |"
    )
    print("|---|---|---|---|---|")
    for name, n, o, h, w in rows:
        print(f"| {name} | {n} | {o} | {h} | {w:.2f} |")

    # the scenario of I13BoundCounterexample.t.sol (rounds 10, six members)
    P = dict(price=10**5 * WAD, k=6, rounds=10, dustIcr=2000, bMult=10, mult=10**4, crashes=1)
    s = list(protocol_valid(P))[-1]
    # ids: A = 1, six members 2-7, eleven dust remainders 8-18, B = 19
    print(
        "\nregression state: LColl",
        s.L,
        "LDebt",
        s.LD,
        "keyA",
        s.eff(1),
        "keyB",
        s.eff(19),
        "stakeB",
        s.m[19][2],
    )
    print(
        "CHG-008 holds on (A, B):",
        (s.eff(1)[0] + s.k(1, True)) * (s.eff(19)[1] + s.k(19, False))
        >= s.eff(19)[0] * s.eff(1)[1],
        "| hidden-key holds:",
        s.h[1] - s.iota[1] <= s.h[19] + s.iota[19],
    )


if __name__ == "__main__":
    main()
