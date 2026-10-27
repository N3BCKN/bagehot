"""The Solidity side of the differential test (P23): deployment A on a local anvil.

One anvil per test session (chain id 31337, anvil's public test mnemonic, unlocked accounts — no key
is ever handled). Deployment goes through `contracts/script/DiffDeploy.s.sol`, which is the audited
`Deploy.deploy` path (local mocks, blueprints, the factory, the §3.3 checks) with nothing written to
`deployments/`. Blocks are mined by hand: every model step becomes exactly one block whose timestamp
is set with `evm_setNextBlockTimestamp` to the model's `now`, holding the step's environment
transactions (feed updates) followed by its operation.

`Chain.snapshot()` reads every compared field through view calls (batched JSON-RPC) into the shape
of `System.snapshot()`: the same keys, integers, addresses as account names, zero balances dropped.
Reverts are decoded to error names from every deployed ABI (custom errors, OZ errors, `Panic`); a
revert that originates inside WETH is reported as `WethTransferFailed` (spec §2.5), found from the
call trace rather than guessed from the selector.

What the harness deliberately does not compare or generate is listed once, with reasons, in
`differential.allowed` — nothing else is excused.
"""

from __future__ import annotations

import json
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from eth_abi import decode as abi_decode
from eth_utils import event_abi_to_log_topic, function_abi_to_4byte_selector, to_checksum_address
from web3 import Web3

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "contracts"
OUT = CONTRACTS / "out"
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ZERO = "0x0"  # the model's name for address(0)
ACTORS = ("alice", "bob", "carol", "dave")
TX_GAS = 30_000_000
PANIC_SELECTOR = bytes.fromhex("4e487b71")
ERROR_STRING_SELECTOR = bytes.fromhex("08c379a0")
NO_OUTPUTS = object()  # `Chain.returned` for a function without return values

# contract name -> artifact (file, contract)
ARTIFACTS = {
    "vault": ("VaultManager.sol", "VaultManager"),
    "sorted": ("SortedPositions.sol", "SortedPositions"),
    "pool": ("StabilityPool.sol", "StabilityPool"),
    "ledger": ("DeficitLedger.sol", "DeficitLedger"),
    "redemption": ("RedemptionModule.sol", "RedemptionModule"),
    "oracle": ("OracleAdapter.sol", "OracleAdapter"),
    "token": ("StableToken.sol", "StableToken"),
    "weth": ("LocalWETH.sol", "LocalWETH"),
    "shutdown": ("StandInShutdownModule.sol", "StandInShutdownModule"),
    "feed": ("MockAggregator.sol", "MockAggregator"),
    "sequencer": ("MockSequencerFeed.sol", "MockSequencerFeed"),
    "factory": ("BagehotFactory.sol", "BagehotFactory"),
}


def _abi(name: str) -> list[dict]:
    file, contract = ARTIFACTS[name]
    return json.loads((OUT / file / f"{contract}.json").read_text())["abi"]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@dataclass
class Outcome:
    """One operation's result on chain: success with its decoded events, or a revert name."""

    ok: bool
    events: list[tuple[str, tuple]] = field(default_factory=list)
    error: str | None = None
    value: object = None  # the return value, filled in by `Chain.returned` for compared calls


class Chain:
    def __init__(self) -> None:
        self.port = _free_port()
        self.proc = subprocess.Popen(
            [
                "anvil",
                "--port",
                str(self.port),
                "--chain-id",
                "31337",
                "--gas-limit",
                "1000000000",
                "--silent",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{self.port}"))
        for _ in range(100):
            try:
                if self.w3.is_connected():
                    break
            except Exception:  # noqa: BLE001 — not up yet
                pass
            time.sleep(0.05)
        else:
            raise RuntimeError("anvil did not start")
        accounts = self.w3.eth.accounts
        self.deployer = accounts[0]
        self.address: dict[str, str] = {a: accounts[i + 1] for i, a in enumerate(ACTORS)}
        self.address["deployer"] = self.deployer  # sends setup and feed transactions only
        self._deploy()
        self.name = {v.lower(): k for k, v in self.address.items()}
        self.name[ZERO_ADDRESS] = ZERO
        self._decoders()
        self._rpc("evm_setAutomine", [False])
        self.max_scale = 0  # the pool's largest `currentScale` seen since the last revert

    # ---- process ----
    def close(self) -> None:
        self.proc.terminate()
        self.proc.wait(timeout=10)

    def _rpc(self, method: str, params: list) -> object:
        r = self.w3.provider.make_request(method, params)
        if "error" in r:
            raise RuntimeError(f"{method}: {r['error']}")
        return r["result"]

    # ---- deployment ----
    def _deploy(self) -> None:
        out = subprocess.run(
            [
                "forge",
                "script",
                "script/DiffDeploy.s.sol:DiffDeploy",
                "--sig",
                "runDiff()",
                "--rpc-url",
                f"http://127.0.0.1:{self.port}",
                "--unlocked",
                "--sender",
                self.deployer,
                "--broadcast",
                "--slow",
            ],
            cwd=CONTRACTS,
            capture_output=True,
            text=True,
            check=False,
        )
        line = next((x for x in out.stdout.splitlines() if "DIFF_DEPLOY" in x), None)
        if out.returncode != 0 or line is None:
            raise RuntimeError(f"DiffDeploy failed:\n{out.stdout[-3000:]}\n{out.stderr[-3000:]}")
        factory, weth, feed, sequencer = line.split()[1:5]
        f = self.w3.eth.contract(address=factory, abi=_abi("factory"))
        self.address |= {
            "factory": factory,
            "weth": weth,
            "feed": feed,
            "sequencer": sequencer,
            "vault": f.functions.vaultManager().call(),
            "sorted": f.functions.sorted().call(),
            "pool": f.functions.stabilityPool().call(),
            "ledger": f.functions.deficitLedger().call(),
            "redemption": f.functions.redemptionModule().call(),
            "oracle": f.functions.oracle().call(),
            "token": f.functions.token().call(),
            "shutdown": f.functions.shutdownModule().call(),
        }
        self.c = {
            n: self.w3.eth.contract(address=self.address[n], abi=_abi(n))
            for n in ARTIFACTS
            if n in self.address
        }
        assert f.functions.strategy().call() == self.address["pool"]

    # ---- decoding ----
    def _decoders(self) -> None:
        self.errors: dict[bytes, tuple[str, list[str]]] = {}
        self.events: dict[bytes, dict] = {}
        for n in ARTIFACTS:
            for item in _abi(n):
                if item["type"] == "error":
                    sel = function_abi_to_4byte_selector(item)
                    self.errors[sel] = (item["name"], [i["type"] for i in item["inputs"]])
                elif item["type"] == "event" and not item.get("anonymous"):
                    self.events[event_abi_to_log_topic(item)] = item

    def _value(self, typ: str, v: object) -> object:
        if typ == "address":
            return self.name.get(v.lower(), v.lower())
        if typ.endswith("[]"):
            return tuple(self._value(typ[:-2], x) for x in v)
        return v

    def decode_log(self, log: dict) -> tuple[str, tuple]:
        abi = self.events[bytes(log["topics"][0])]
        indexed = [i for i in abi["inputs"] if i["indexed"]]
        plain = [i for i in abi["inputs"] if not i["indexed"]]
        topics = iter(log["topics"][1:])
        data = iter(abi_decode([i["type"] for i in plain], bytes(log["data"])))
        values = []
        for i in abi["inputs"]:
            raw = abi_decode([i["type"]], bytes(next(topics)))[0] if i["indexed"] else next(data)
            values.append(self._value(i["type"], raw))
        emitter = self.name.get(log["address"].lower(), log["address"])
        del indexed
        return emitter, (abi["name"], *values)

    def decode_error(self, data: bytes) -> str:
        sel = data[:4]
        if sel == PANIC_SELECTOR:
            return f"Panic(0x{abi_decode(['uint256'], data[4:])[0]:02x})"
        if sel == ERROR_STRING_SELECTOR:
            return f"Error({abi_decode(['string'], data[4:])[0]})"
        if sel in self.errors:
            return self.errors[sel][0]
        return f"unknown(0x{data.hex()})"

    def _revert(self, tx_hash: bytes) -> str:
        """The revert's name; a revert raised inside WETH is `WethTransferFailed` (§2.5)."""
        trace = self._rpc("debug_traceTransaction", [tx_hash.hex(), {"tracer": "callTracer"}])

        def origin(call: dict) -> dict:
            for sub in call.get("calls", []) or []:
                if sub.get("error") and sub.get("output") == call.get("output"):
                    return origin(sub)
            return call

        top = origin(trace)
        if top.get("to", "").lower() == self.address["weth"].lower():
            return "WethTransferFailed"
        out = trace.get("output") or "0x"
        return self.decode_error(bytes.fromhex(out[2:]))

    def returned(self, tx_hash: bytes, contract: str, fn: str) -> object:
        """A successful call's return value, from the call trace: the value for one output, a
        tuple for several (as the model's `Receipt.value`), `NO_OUTPUTS` for a function that
        declares none."""
        types = [o["type"] for o in self.c[contract].get_function_by_name(fn).abi["outputs"]]
        if not types:
            return NO_OUTPUTS
        trace = self._rpc("debug_traceTransaction", [tx_hash.hex(), {"tracer": "callTracer"}])
        raw = abi_decode(types, bytes.fromhex((trace.get("output") or "0x")[2:]))
        values = tuple(self._value(t, x) for t, x in zip(types, raw, strict=True))
        return values[0] if len(values) == 1 else values

    # ---- blocks ----
    def send(self, sender: str, contract: str, fn: str, *args: object) -> bytes:
        call = getattr(self.c[contract].functions, fn)(*args)
        frm = self.address[sender]
        return self.w3.eth.send_transaction(
            call.build_transaction({"from": frm, "gas": TX_GAS, "nonce": self._nonce(frm)})
        )

    def _nonce(self, frm: str) -> int:
        return self.w3.eth.get_transaction_count(frm, "pending")

    def mine(self, timestamp: int) -> None:
        self._rpc("evm_setNextBlockTimestamp", [timestamp])
        self._rpc("evm_mine", [])

    def outcome(self, tx_hashes: list[bytes]) -> Outcome:
        """The receipts of one operation's transactions (all in the block just mined)."""
        events: list[tuple[str, tuple]] = []
        for h in tx_hashes:
            r = self.w3.eth.get_transaction_receipt(h)
            if r.status != 1:
                return Outcome(False, [], self._revert(h))
            events += [self.decode_log(log) for log in r.logs]
        return Outcome(True, events)

    def impersonate(self, name: str) -> None:
        a = self.address[name]
        self._rpc("anvil_impersonateAccount", [a])
        self._rpc("anvil_setBalance", [a, hex(10**30)])

    def timestamp(self) -> int:
        return self.w3.eth.get_block("latest").timestamp

    def snapshot_id(self) -> str:
        return self._rpc("evm_snapshot", [])

    def revert_to(self, sid: str) -> None:
        # transactions left unmined by an aborted step would otherwise land in the next block
        self._rpc("anvil_dropAllTransactions", [])
        assert self._rpc("evm_revert", [sid]) is True
        self.max_scale = 0

    # ---- state ----
    def snapshot(self, holders: set[str], s_keys: set[tuple[int, int]]) -> dict:
        """Every compared field, read in two batches. `holders` are the account names whose token
        balances and deposit records to read (with every known address; `totalSupply` catches a
        balance anywhere else); `s_keys` the (epoch, scale) keys the model knows, read with every
        scale up to one above the largest the chain has reached, in every epoch."""
        from model.protocol.system import _canon  # noqa: PLC0415 — the same canonical form

        c = self.c
        v, srt, pool, led, r, o = (
            c[n].functions for n in ("vault", "sorted", "pool", "ledger", "redemption", "oracle")
        )
        scalars = {
            ("vault", k): getattr(v, k)()
            for k in (
                "index",
                "lastAccrual",
                "nextId",
                "activeCount",
                "totalNormDebt",
                "totalCollateral",
                "totalStakes",
                "totalStakesSnapshot",
                "totalCollateralSnapshot",
                "LColl",
                "LDebt",
                "lastErrorColl",
                "lastErrorDebt",
                "pendingColl",
                "pendingNormDebt",
                "shutdown",
                "settled",
            )
        }
        scalars |= {
            ("sorted", k): getattr(srt, g)()
            for k, g in (("head", "getFirst"), ("tail", "getLast"), ("size", "getSize"))
        }
        scalars |= {
            ("pool", k): getattr(pool, k)()
            for k in (
                "totalDeposits",
                "P",
                "currentScale",
                "currentEpoch",
                "lastCollError",
                "lastInterestError",
                "collGainsBalance",
                "interestGainsBalance",
            )
        }
        scalars |= {
            ("redemption", k): getattr(r, k)() for k in ("baseRate", "lastFeeOperationTime")
        }
        scalars |= {
            ("ledger", k): getattr(led, k)()
            for k in ("reserve", "auctionDebt", "deficit", "recoveredColl", "settled")
        }
        scalars |= {("oracle", k): getattr(o, k)() for k in ("lastGoodPrice", "failureStart")}
        names = sorted(holders | set(self.address) - {"factory", "feed", "sequencer", "deployer"})
        for t in ("weth", "token"):
            scalars[(t, "totalSupply")] = c[t].functions.totalSupply()
            for a in names:
                scalars[(t, a)] = c[t].functions.balanceOf(self.address[a])
        for a in names:
            scalars[("deposit", a)] = pool.deposits(self.address[a])
        first = self._batch(scalars)
        s = {k: first[k] for k in scalars}

        second: dict = {}
        for pid in range(1, s[("vault", "nextId")]):
            second[("position", pid)] = v.positions(pid)
            second[("contains", pid)] = srt.contains(pid)
            second[("prev", pid)] = srt.getPrev(pid)
            second[("next", pid)] = srt.getNext(pid)
        epochs = range(s[("pool", "currentEpoch")] + 1)
        # every scale the chain can have written in any epoch, not only the keys the model knows
        self.max_scale = max(self.max_scale, s[("pool", "currentScale")])
        scales = {sc for _, sc in s_keys} | set(range(self.max_scale + 2))
        for e in epochs:
            second[("count", e)] = pool.depositorCount(e)
            for sc in scales:
                second[("S", e, sc)] = pool.epochToScaleToS(e, sc)
                second[("G", e, sc)] = pool.epochToScaleToG(e, sc)
        s2 = self._batch(second)

        positions = {}
        nodes = {}
        for pid in range(1, s[("vault", "nextId")]):
            p = s2[("position", pid)]
            positions[pid] = {
                "owner": self.name.get(p[0].lower(), p[0].lower()),
                "coll": p[1],
                "normDebt": p[2],
                "stake": p[3],
                "snapLColl": p[4],
                "snapLDebt": p[5],
                "status": p[6],
            }
            if s2[("contains", pid)]:
                nodes[pid] = {"prev": s2[("prev", pid)], "next": s2[("next", pid)]}
        deposits = {}
        for a in names:
            d = s[("deposit", a)]
            if d[0]:
                deposits[a] = dict(
                    zip(
                        ("initial", "snapP", "snapS", "snapG", "snapEpoch", "snapScale"),
                        d,
                        strict=True,
                    )
                )

        def acc(tag: str) -> dict:
            out: dict = {}
            for e in epochs:
                for sc in scales:
                    if x := s2[(tag, e, sc)]:
                        out.setdefault(e, {})[sc] = x
            return out

        def token(t: str) -> dict:
            bal = {a: s[(t, a)] for a in names if s[(t, a)]}
            return {"totalSupply": s[(t, "totalSupply")], "balances": bal}

        def section(tag: str) -> dict:
            return {k: x for (sec, k), x in s.items() if sec == tag}

        vault = section("vault") | {"positions": positions}
        return _canon(
            {
                "now": self.timestamp(),
                "vault": vault,
                "sorted": section("sorted") | {"nodes": nodes},
                "pool": section("pool")
                | {
                    "epochToScaleToS": acc("S"),
                    "epochToScaleToG": acc("G"),
                    "deposits": deposits,
                    "depositorCount": {e: s2[("count", e)] for e in epochs if s2[("count", e)]},
                },
                "redemption": section("redemption"),
                "ledger": section("ledger"),
                "oracle": section("oracle"),
                "weth": token("weth"),
                "token": token("token"),
            }
        )

    def _batch(self, calls: dict) -> dict:
        keys = list(calls)
        with self.w3.batch_requests() as batch:
            for k in keys:
                batch.add(calls[k])
            results = batch.execute()
        return dict(zip(keys, results, strict=True))

    def checksum(self, a: str) -> str:
        return to_checksum_address(a)
