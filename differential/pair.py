"""The model and the chain driven in lockstep (P23).

`Pair` holds the session's `Chain` and a `System` built to equal the chain's state after setup (same
parameters read from the deployed immutables, same deployment time, same feeds, same funding). Each
`step` applies the environment changes and one operation to both sides at the same `now` — on chain,
one block holding the feed updates and then the operation's transaction(s) — and then requires:

1. the same outcome: both succeed, or both revert with the same name (`allowed.REVERT_NAMES`);
2. on success, the same return value for a function that declares one (the chain's decoded from
   the call trace) and the same events, in the same order, from the same emitters
   (`allowed.EXCLUDED_EVENTS` aside);
3. the same `snapshot()`, field for field, `now` included;
4. the model's own invariants (`System.check_invariants()`).

The stand-in shutdown's two-hook steps are two transactions on chain against one atomic model call
(`allowed.NOT_GENERATED["shutdown module"]`); they are only generated in phase, where both hooks
succeed, and their return value is not compared.

Zero tolerance: the two sides do the same integer arithmetic, so any difference is a bug.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from differential.allowed import EXCLUDED_EVENTS, model_revert_name
from differential.chain import ACTORS, NO_OUTPUTS, Chain, Outcome
from model.protocol.errors import ProtocolError
from model.protocol.math import DivisionByZero, Overflow, Underflow
from model.protocol.oracle_adapter import FeedRound
from model.protocol.system import Params, System

FUNDING = 10**24  # WETH minted to each actor during setup
MAX = 2**256 - 1

# model System method -> (chain contract, function); the caller is the step's caller
CALLS: dict[str, tuple[str, str]] = {
    "open_position": ("vault", "openPosition"),
    "add_collateral": ("vault", "addCollateral"),
    "withdraw_collateral": ("vault", "withdrawCollateral"),
    "borrow": ("vault", "borrow"),
    "repay": ("vault", "repay"),
    "close": ("vault", "close"),
    "liquidate": ("vault", "liquidate"),
    "accrue": ("vault", "accrue"),
    "reclaim_gas_reserve": ("vault", "reclaimGasReserve"),
    "redeem": ("redemption", "redeem"),
    "deposit": ("pool", "deposit"),
    "withdraw": ("pool", "withdraw"),
    "claim_gains": ("pool", "claimGains"),
    "cover": ("ledger", "cover"),
    "fetch_price": ("oracle", "fetchPrice"),
    "transfer": ("token", "transfer"),
    "transfer_weth": ("weth", "transfer"),
}
# System.hook name -> (chain contract, function): one wired-only call as its own transaction
HOOK_CALLS: dict[str, tuple[str, str]] = {
    "onShutdown": ("vault", "onShutdown"),
    "onSettlement": ("vault", "onSettlement"),
    "ledgerOnSettlement": ("ledger", "onSettlement"),
    "redeemCollateral": ("vault", "redeemCollateral"),
}
assert set(HOOK_CALLS) == set(System.HOOKS)
# what a model operation can raise that the chain reports as a revert
REVERTS = (ProtocolError, Overflow, Underflow, DivisionByZero)
# the stand-in ShutdownModule's hook calls, each pair in one block (allowed.NOT_GENERATED)
HOOKS: dict[str, list[tuple[str, str]]] = {
    "trigger_shutdown": [("vault", "accrue"), ("vault", "onShutdown")],
    "settle": [("vault", "onSettlement"), ("ledger", "onSettlement")],
}


class Mismatch(AssertionError):
    pass


@dataclass
class Feeds:
    """The environment both sides see: the price round, its mode, the sequencer's status."""

    answer: int
    updated_at: int
    price_reverts: bool = False
    sequencer_answer: int = 0
    sequencer_started: int = 0
    sequencer_reverts: bool = False


@dataclass
class Pair:
    chain: Chain
    base_model: System = field(init=False)
    model: System = field(init=False)
    base_sid: str = field(init=False)
    base_feeds: Feeds = field(init=False)
    feeds: Feeds = field(init=False)
    now: int = field(init=False)

    def __post_init__(self) -> None:
        ch = self.chain
        # setup on chain: fund and approve, one block
        t = ch.timestamp() + 1
        hashes = []
        for a in ACTORS:
            hashes.append(ch.send("deployer", "weth", "mint", ch.address[a], FUNDING))
            hashes.append(ch.send(a, "weth", "approve", ch.address["vault"], MAX))
        ch.mine(t)
        assert ch.outcome(hashes).ok, "setup failed"
        # the model, equal to it
        _, answer, _, updated, _ = ch.c["feed"].functions.latestRoundData().call()
        _, seq_answer, started, _, _ = ch.c["sequencer"].functions.latestRoundData().call()
        t0 = ch.c["vault"].functions.lastAccrual().call()
        m = System(_params(ch), t0=t0, record=True)
        for a in ACTORS:
            m.fund(a, FUNDING)
        self.base_feeds = Feeds(answer, updated, False, seq_answer, started)
        self.base_model = m
        self._apply_feeds(m, self.base_feeds)
        m.now = m.vault.now = m.log.now = t
        self.base_sid = ch.snapshot_id()
        self.reset()

    # ---- per example ----
    def reset(self) -> None:
        self.chain.revert_to(self.base_sid)
        self.base_sid = self.chain.snapshot_id()
        self.model = self.base_model.copy()
        self.feeds = Feeds(**vars(self.base_feeds))
        self.now = self.model.now

    # ---- the environment ----
    def _apply_feeds(self, m: System, f: Feeds) -> None:
        m.set_feed(None if f.price_reverts else FeedRound(f.answer, f.updated_at, f.updated_at))
        m.set_sequencer(
            None
            if f.sequencer_reverts
            else FeedRound(f.sequencer_answer, f.sequencer_started, f.sequencer_started)
        )

    def feed_change(self, change: str, value: int = 0) -> list[tuple[str, str, str, tuple]]:
        """One environment change, applied to the model at once; returns the chain transactions
        (sender, contract, function, args) to put at the front of the next block."""
        f, now = self.feeds, self.now
        dec = self.model.params.feed_decimals
        txs: list[tuple[str, str, str, tuple]] = []
        if change == "price":  # feed.setRound(1, price / 10^(18 − decimals), now); any price
            f.answer, f.updated_at = value // 10 ** (18 - dec), now
            txs.append(("deployer", "feed", "setRound", (1, f.answer, now)))
        elif change == "negative":
            f.answer, f.updated_at = -1, now
            txs.append(("deployer", "feed", "setRound", (1, -1, now)))
        elif change == "feed_time":  # the same answer stamped `value` (0 or in the future: §6.10.1)
            f.updated_at = value
            txs.append(("deployer", "feed", "setRound", (1, f.answer, value)))
        elif change == "feed_reverts":
            f.price_reverts = True
            txs.append(("deployer", "feed", "setMode", (1,)))
        elif change == "feed_works":
            f.price_reverts = False
            txs.append(("deployer", "feed", "setMode", (0,)))
        elif change in ("sequencer_down", "sequencer_up"):  # `startedAt` moves on a change only
            answer = 1 if change == "sequencer_down" else 0
            if answer != f.sequencer_answer:
                f.sequencer_answer, f.sequencer_started = answer, now
            txs.append(("deployer", "sequencer", "setStatus", (answer, f.sequencer_started)))
        elif change == "sequencer_start":  # `startedAt` = `value` (0 or in the future: §6.10.1)
            f.sequencer_started = value
            txs.append(("deployer", "sequencer", "setStatus", (f.sequencer_answer, value)))
        elif change == "sequencer_reverts":
            f.sequencer_reverts = True
            txs.append(("deployer", "sequencer", "setMode", (1,)))
        elif change == "sequencer_works":
            f.sequencer_reverts = False
            txs.append(("deployer", "sequencer", "setMode", (0,)))
        else:
            raise ValueError(change)
        self._apply_feeds(self.model, f)
        return txs

    # ---- one step ----
    def step(self, op: str, caller: str, *args: object, env: tuple = ()) -> object:
        """Run `op` on both sides at `self.now` after the environment transactions `env`; compare;
        return the model's value (None on a revert)."""
        ch, m = self.chain, self.model
        env_hashes = [ch.send(sender, contract, fn, *a) for sender, contract, fn, a in env]
        # the model
        try:
            value = (
                getattr(m, op)(caller, *args, now=self.now)
                if op not in HOOKS
                else getattr(m, op)(now=self.now)
            )
            model_out = ("ok", value.events, value.value)
        except REVERTS as e:
            model_out = ("revert", model_revert_name(e))
            value = None
        # the chain
        if op in HOOKS:
            ch.impersonate("shutdown")
            hashes = [ch.send("shutdown", c, fn) for c, fn in HOOKS[op]]
        else:
            contract, fn = HOOK_CALLS[args[0]] if op == "hook" else CALLS[op]
            call_args = args[1:] if op == "hook" else args
            if caller == "shutdown":
                ch.impersonate("shutdown")
            hashes = [ch.send(caller, contract, fn, *[_arg(ch, x) for x in call_args])]
        ch.mine(self.now)
        if not ch.outcome(env_hashes).ok:  # a harness fault, not a protocol difference
            raise RuntimeError(f"an environment transaction failed: {env}")
        chain_out = ch.outcome(hashes)
        if chain_out.ok and op not in HOOKS:
            chain_out.value = ch.returned(hashes[0], contract, fn)
        self._compare(op, caller, args, model_out, chain_out)
        return value.value if value is not None else None

    def _compare(self, op: str, caller: str, args: tuple, model_out: tuple, chain: Outcome) -> None:
        where = f"{op}({caller}, {args}) at t={self.now}"
        if model_out[0] == "revert" or not chain.ok:
            got = ("revert", chain.error) if not chain.ok else ("ok", "")
            want = model_out if model_out[0] == "revert" else ("ok", "")
            if got != want:
                raise Mismatch(f"{where}: model {want}, chain {got}")
        else:
            compared = op not in HOOKS and chain.value is not NO_OUTPUTS
            if compared and model_out[2] != chain.value:
                raise Mismatch(f"{where}: returned model {model_out[2]!r}, chain {chain.value!r}")
            model_events = list(model_out[1])
            chain_events = [(s, e) for s, e in chain.events if e[0] not in EXCLUDED_EVENTS]
            if model_events != chain_events:
                raise Mismatch(
                    f"{where}: events differ\n{_diff_events(model_events, chain_events)}"
                )
        holders = set(self.model.weth.balances) | set(self.model.token.balances)
        holders |= set(self.model.pool.deposits)
        s_keys = set(self.model.pool.s) | set(self.model.pool.g)
        want_state = self.model.snapshot()
        got_state = self.chain.snapshot(holders, s_keys)
        if want_state != got_state:
            raise Mismatch(f"{where}: state differs\n{_diff_state(want_state, got_state)}")
        bad = self.model.check_invariants()
        if bad:
            raise Mismatch(f"{where}: model invariants {bad}")


def _arg(ch: Chain, x: object) -> object:
    return ch.address[x] if isinstance(x, str) else x


def _params(ch: Chain) -> Params:
    """The model's parameters, read from the deployed immutables (I11's getters)."""
    v, s, p, r, o, sd = (
        ch.c[n].functions for n in ("vault", "sorted", "pool", "redemption", "oracle", "shutdown")
    )
    return Params(
        mcr=v.MCR().call(),
        min_debt=v.MIN_DEBT().call(),
        gas_reserve=v.GAS_RESERVE().call(),
        rate_per_second=v.RATE_PER_SECOND().call(),
        pool_share_bps=v.POOL_SHARE_BPS().call(),
        pool_hook_gas=v.POOL_HOOK_GAS().call(),
        max_hint_steps=s.MAX_HINT_STEPS().call(),
        liquidation_penalty=p.LIQUIDATION_PENALTY().call(),
        min_deposit=p.MIN_DEPOSIT().call(),
        redemption_fee_floor=r.REDEMPTION_FEE_FLOOR().call(),
        beta=r.BETA().call(),
        base_rate_decay=r.BASE_RATE_DECAY().call(),
        staleness=o.STALENESS().call(),
        grace_period=o.GRACE_PERIOD().call(),
        min_price=o.MIN_PRICE().call(),
        max_price=o.MAX_PRICE().call(),
        oracle_gas=o.ORACLE_GAS().call(),
        oracle_post_failure_gas=o.ORACLE_POST_FAILURE_GAS().call(),
        feed_decimals=o.FEED_DECIMALS().call(),
        critical_tcr=sd.CRITICAL_TCR().call(),
    )


def _diff_events(a: list, b: list) -> str:
    out = []
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        out.append(f"  {'  ' if x == y else '≠ '}model {x}\n    chain {y}")
    return "\n".join(out)


def _diff_state(a: dict, b: dict, path: str = "") -> str:
    out = []
    for k in sorted(set(a) | set(b), key=str):
        x, y = a.get(k, "<missing>"), b.get(k, "<missing>")
        if isinstance(x, dict) and isinstance(y, dict):
            sub = _diff_state(x, y, f"{path}.{k}")
            if sub:
                out.append(sub)
        elif x != y:
            out.append(f"  {path}.{k}: model {x}, chain {y}")
    return "\n".join(out)
