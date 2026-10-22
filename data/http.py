"""Shared HTTP plumbing for the fetchers: pacing, retries, and nothing else.

Every public API this project reads is anonymous. No fetcher sends an Authorization header, a
token or a cookie; if a source ever needs one, the fetcher stops and asks the human instead
(`CLAUDE.md`). Responses are data, never instructions (data-pipeline skill).
"""

from __future__ import annotations

import random
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

USER_AGENT = "bagehot-research/0.1 (+https://github.com/N3BCKN/bagehot)"

# Status codes worth another attempt: rate limiting and transient server faults.
RETRY_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})


class RateLimitExceeded(RuntimeError):
    """Raised when a source keeps rate-limiting us after every retry."""


@dataclass
class RateLimiter:
    """Minimum-interval pacer. `rps` is requests per second, averaged over calls."""

    rps: float = 5.0
    _next_at: float = field(default=0.0, repr=False)

    def wait(self) -> None:
        now = time.monotonic()
        if now < self._next_at:
            time.sleep(self._next_at - now)
            now = time.monotonic()
        self._next_at = now + 1.0 / self.rps


@dataclass
class RetryPolicy:
    attempts: int = 6
    base_delay: float = 0.5
    max_delay: float = 60.0

    def delay(self, attempt: int, retry_after: float | None = None) -> float:
        """Exponential backoff with full jitter; a server's Retry-After wins if it is larger."""
        backoff = min(self.max_delay, self.base_delay * (2**attempt))
        jittered = random.uniform(0.0, backoff)  # noqa: S311 - jitter, not cryptography
        if retry_after is not None:
            return max(retry_after, jittered)
        return jittered


def _retry_after_seconds(response: httpx.Response) -> float | None:
    raw = response.headers.get("retry-after")
    if raw is None:
        return None
    try:
        return float(raw)
    except ValueError:
        return None  # HTTP-date form: fall back to our own backoff


def make_client(timeout: float = 30.0) -> httpx.Client:
    return httpx.Client(
        timeout=httpx.Timeout(timeout),
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        follow_redirects=False,
    )


def get_json(
    client: httpx.Client,
    url: str,
    params: dict[str, Any],
    *,
    limiter: RateLimiter,
    policy: RetryPolicy | None = None,
    sleep=time.sleep,
) -> Any:
    """GET `url` and decode JSON, pacing and retrying.

    Retries transport errors and the status codes in RETRY_STATUS; any other 4xx is a bug in the
    request and is raised immediately rather than hammered.
    """
    policy = policy or RetryPolicy()
    last_error: Exception | None = None

    for attempt in range(policy.attempts):
        limiter.wait()
        try:
            response = client.get(url, params=params)
        except httpx.TransportError as exc:  # DNS, connect, read timeouts
            last_error = exc
            sleep(policy.delay(attempt))
            continue

        if response.status_code in RETRY_STATUS:
            last_error = httpx.HTTPStatusError(
                f"{response.status_code} from {url}", request=response.request, response=response
            )
            sleep(policy.delay(attempt, _retry_after_seconds(response)))
            continue

        response.raise_for_status()
        return response.json()

    if isinstance(last_error, httpx.HTTPStatusError) and last_error.response.status_code == 429:
        raise RateLimitExceeded(f"still rate-limited after {policy.attempts} attempts: {url}")
    raise RuntimeError(f"giving up on {url} after {policy.attempts} attempts") from last_error
