"""The differential state machine over the session's anvil (P23). Settings come from the active
Hypothesis profile (`--hypothesis-profile=quick|nightly`, differential/conftest.py)."""

from __future__ import annotations

from hypothesis import settings
from hypothesis.stateful import run_state_machine_as_test

from differential.machine import DiffMachine


def test_model_and_chain_agree_step_by_step(pair) -> None:  # noqa: ANN001
    DiffMachine.pair = pair
    run_state_machine_as_test(DiffMachine, settings=settings())
