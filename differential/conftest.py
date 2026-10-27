"""Differential test configuration (P23): Hypothesis profiles, the session's anvil, the seed.

Profiles: `quick` (CI on every PR, `just diff-quick`) and `nightly` (`just diff-long`, ≥ 2,000
examples). The run's seed is fixed before Hypothesis starts — `--hypothesis-seed` if given, a fresh
one otherwise — and printed in the summary of a failing run, so any failure can be replayed exactly:
`uv run pytest differential --hypothesis-profile=<profile> --hypothesis-seed=<seed>`.
"""

from __future__ import annotations

import random
import shutil

import pytest
from hypothesis import HealthCheck, settings

settings.register_profile(
    "quick",
    max_examples=40,
    stateful_step_count=30,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
    print_blob=True,
)
settings.register_profile(
    "nightly",
    max_examples=2_000,
    stateful_step_count=40,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
    print_blob=True,
)


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config: pytest.Config) -> None:
    # before Hypothesis's own pytest_configure reads it, so the seed below is the one it uses
    if config.getoption("hypothesis_seed", None) is None:
        config.option.hypothesis_seed = random.SystemRandom().randrange(2**32)


def pytest_terminal_summary(terminalreporter, exitstatus: int, config: pytest.Config) -> None:  # noqa: ANN001
    if exitstatus != 0:
        seed = config.getoption("hypothesis_seed")
        terminalreporter.write_line(
            f"differential seed: {seed} — replay with --hypothesis-seed={seed}", red=True
        )


@pytest.fixture(scope="session")
def chain():  # noqa: ANN201
    from differential.chain import Chain  # noqa: PLC0415

    if shutil.which("anvil") is None or shutil.which("forge") is None:
        pytest.fail("the differential test needs anvil and forge (Foundry) on PATH")
    ch = Chain()
    yield ch
    ch.close()


@pytest.fixture(scope="session")
def pair(chain):  # noqa: ANN001, ANN201
    from differential.pair import Pair  # noqa: PLC0415

    return Pair(chain)
