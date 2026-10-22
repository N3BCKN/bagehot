"""Minimal JSON-RPC client for read-only archive queries, with the endpoint kept out of every log.

Why not web3's HTTP provider: its exceptions quote the endpoint URL ("... for url: https://..."),
and an archive URL usually carries an API key in its path. This client never stores the URL in an
exception message, raises its own errors `from None` so no chained traceback can echo it, and has
no `__repr__` that would print it (`CLAUDE.md`: never write RPC URLs with embedded keys into logs).

It only reads. There is no `eth_sendRawTransaction` here and there never will be: Base mainnet is
read-only for this project (ADR-0019).
"""

from __future__ import annotations

import os
import re
from typing import Any

import httpx

from data.http import RETRY_STATUS, RateLimiter, RetryPolicy

ENV_VAR = "BASE_ARCHIVE_RPC"

# Messages providers use when an eth_getLogs range or result set is too large. Matched loosely on
# purpose: the providers disagree on codes, and halving on a false positive only costs a request.
RANGE_TOO_LARGE = re.compile(
    r"(block range|range (is )?too (large|big|wide)|too many|more than \d+ (results|logs)"
    r"|exceed|limit(ed)? to|response size|query timeout|log response)",
    re.IGNORECASE,
)


class RpcError(RuntimeError):
    """A JSON-RPC error object returned by the node. Message is the node's, never the URL."""

    def __init__(self, code: int | None, message: str):
        super().__init__(f"rpc error {code}: {message}")
        self.code = code
        self.message = message


class RangeTooLarge(RpcError):
    """The provider refused an eth_getLogs range; the caller should halve it."""


class RpcUnavailable(RuntimeError):
    """Transport or HTTP failure after every retry. Deliberately carries no URL."""


def _scrub(text: str, secret: str) -> str:
    if secret and secret in text:
        text = text.replace(secret, "<rpc>")
    # Belt and braces: any URL at all is replaced, in case the provider echoes a variant of it.
    return re.sub(r"https?://\S+", "<url>", text)


class Rpc:
    """JSON-RPC over HTTP POST. `requests` counts every attempt that reached the wire."""

    __slots__ = ("_url", "_client", "_limiter", "_policy", "_next_id", "requests", "_sleep")

    def __init__(
        self,
        url: str,
        *,
        rps: float = 10.0,
        policy: RetryPolicy | None = None,
        client: httpx.Client | None = None,
        sleep=None,
    ):
        if not url:
            raise RpcUnavailable(f"{ENV_VAR} is empty")
        self._url = url
        self._client = client or httpx.Client(
            timeout=httpx.Timeout(60.0), headers={"Content-Type": "application/json"}
        )
        self._limiter = RateLimiter(rps=rps)
        self._policy = policy or RetryPolicy()
        self._next_id = 1
        self.requests = 0
        import time

        self._sleep = sleep or time.sleep

    @classmethod
    def from_env(cls, **kwargs) -> Rpc:
        url = os.environ.get(ENV_VAR, "")
        if not url:
            raise SystemExit(
                f"{ENV_VAR} is not set. Put it in .env (run through `just`, which loads .env), "
                "or export it in the shell. It is never printed."
            )
        return cls(url, **kwargs)

    def __repr__(self) -> str:  # never show the endpoint
        return f"Rpc(requests={self.requests})"

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> Rpc:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ------------------------------------------------------------------ transport
    def call(self, method: str, params: list[Any]) -> Any:
        body = {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params}
        self._next_id += 1
        last = "no attempt made"

        for attempt in range(self._policy.attempts):
            self._limiter.wait()
            self.requests += 1
            try:
                response = self._client.post(self._url, json=body)
            except httpx.TransportError as exc:
                last = f"{type(exc).__name__}"  # the class name only: messages can hold the URL
                self._sleep(self._policy.delay(attempt))
                continue

            if response.status_code == 413:
                raise RangeTooLarge(413, "payload too large") from None
            if response.status_code in RETRY_STATUS:
                last = f"HTTP {response.status_code}"
                self._sleep(self._policy.delay(attempt))
                continue
            if response.status_code >= 400:
                raise RpcUnavailable(f"{method}: HTTP {response.status_code}") from None

            try:
                payload = response.json()
            except ValueError:
                raise RpcUnavailable(f"{method}: response is not JSON") from None

            error = payload.get("error")
            if error:
                code = error.get("code")
                message = _scrub(str(error.get("message", "")), self._url)
                if method == "eth_getLogs" and RANGE_TOO_LARGE.search(message):
                    raise RangeTooLarge(code, message) from None
                if code in (-32005, 429) or "rate" in message.lower():
                    last = f"rpc {code}: {message}"
                    self._sleep(self._policy.delay(attempt))
                    continue
                raise RpcError(code, message) from None
            return payload["result"]

        raise RpcUnavailable(f"{method}: giving up after {self._policy.attempts} attempts ({last})")

    # ------------------------------------------------------------------ helpers
    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def get_block_timestamp(self, number: int) -> int:
        block = self.call("eth_getBlockByNumber", [hex(number), False])
        if block is None:
            raise RpcError(None, f"block {number} not found")
        return int(block["timestamp"], 16)

    def eth_call(self, to: str, data: str, block: int) -> str:
        """Always at an explicit block (data-pipeline skill: archive calls never use 'latest')."""
        return self.call("eth_call", [{"to": to, "data": data}, hex(block)])

    def get_code(self, address: str, block: int) -> str:
        return self.call("eth_getCode", [address, hex(block)])

    def get_logs(self, address: str, topics: list[str], from_block: int, to_block: int) -> list:
        return self.call(
            "eth_getLogs",
            [
                {
                    "address": address,
                    "topics": topics,
                    "fromBlock": hex(from_block),
                    "toBlock": hex(to_block),
                }
            ],
        )
