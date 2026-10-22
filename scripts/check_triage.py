#!/usr/bin/env python3
"""Fail if slither or aderyn reports a finding not triaged in docs/static-analysis-triage.md.

Matching is by detector + location, exactly as the triage table records them. A finding with
no row is a new finding: fix it, or add a row with a justification a reviewer can disagree
with. Never add a row merely to turn this green — the justification column is read by a human.

Standard library only, so CI can run it without building the project's Python environment.

Usage:
    python3 scripts/check_triage.py [slither.json] [triage.md] [--aderyn aderyn.json]

aderyn is gated when --aderyn is given (P10 closed open issue P01-4); its rows carry `aderyn` in
the tool column and are matched the same way, by detector + location.
"""

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_JSON = REPO / "reports" / "static" / "slither.json"
DEFAULT_TRIAGE = REPO / "docs" / "static-analysis-triage.md"

# Columns of the triage table, in order. A row with a different width is malformed.
COLUMNS = ("id", "tool", "detector", "location", "severity", "decision", "justification", "date")
DECISIONS = {"fixed", "accepted", "false-positive"}
GATED_TOOLS = {"slither", "aderyn"}


class TriageError(Exception):
    """The triage file or the slither output could not be used as a gate."""


def parse_triage(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    """Return (rows, problems) for the gated rows (slither, aderyn) of the triage table."""
    if not path.is_file():
        raise TriageError(f"triage file not found: {path}")

    rows: list[dict[str, str]] = []
    problems: list[str] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line.startswith("|") or not line.endswith("|"):
            continue
        cells = [c.strip() for c in line[1:-1].split("|")]
        if cells == list(COLUMNS) or all(set(c) <= set("-: ") for c in cells):
            continue  # header or separator
        if not any(cells):
            continue  # the empty placeholder row
        if len(cells) != len(COLUMNS):
            problems.append(f"{path.name}:{lineno}: row has {len(cells)} cells, expected 8")
            continue
        row = dict(zip(COLUMNS, cells, strict=True))
        row["tool"] = row["tool"].lower()
        if row["tool"] not in GATED_TOOLS:
            continue  # future tools are not gated by this script
        for field in ("detector", "location", "decision", "justification"):
            if not row[field]:
                problems.append(f"{path.name}:{lineno}: row {row['id'] or '?'} has no {field}")
        if row["decision"] and row["decision"].lower() not in DECISIONS:
            problems.append(
                f"{path.name}:{lineno}: decision {row['decision']!r} is not one of "
                f"{sorted(DECISIONS)}"
            )
        row["_line"] = str(lineno)
        rows.append(row)
    return rows, problems


def primary_location(finding: dict) -> str:
    """file:line of the first element slither could place, or '?' if it placed none."""
    for element in finding.get("elements") or []:
        mapping = element.get("source_mapping") or {}
        filename = mapping.get("filename_relative") or mapping.get("filename_short")
        lines = mapping.get("lines") or []
        if filename and lines:
            return f"{filename}:{lines[0]}"
        if filename:
            return filename
    return "?"


def load_aderyn(path: Path) -> list[tuple[str, str, str, str]]:
    """(detector, location, severity, title) for every instance aderyn reported."""
    if not path.is_file():
        raise TriageError(f"aderyn output not found: {path}. aderyn did not run — fix that first.")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise TriageError(f"{path} is not valid JSON: {exc}") from exc
    out = []
    for key, severity in (("high_issues", "High"), ("low_issues", "Low")):
        for issue in (payload.get(key) or {}).get("issues") or []:
            for inst in issue.get("instances") or []:
                location = f"{inst.get('contract_path', '?')}:{inst.get('line_no', '?')}"
                out.append(
                    (issue.get("detector_name", "?"), location, severity, issue.get("title", ""))
                )
    return out


def load_findings(path: Path) -> list[dict]:
    if not path.is_file():
        raise TriageError(
            f"slither output not found: {path}. slither did not run — fix that first, "
            "rather than skipping the gate."
        )
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise TriageError(f"{path} is not valid JSON: {exc}") from exc
    if not payload.get("success", False):
        raise TriageError(f"slither reported failure: {payload.get('error')!r}")
    return list((payload.get("results") or {}).get("detectors") or [])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slither_json", nargs="?", type=Path, default=DEFAULT_JSON)
    parser.add_argument("triage_md", nargs="?", type=Path, default=DEFAULT_TRIAGE)
    parser.add_argument("--aderyn", type=Path, default=None, help="aderyn JSON report to gate")
    args = parser.parse_args()

    try:
        rows, problems = parse_triage(args.triage_md)
        findings = [
            (
                "slither",
                f.get("check", "?"),
                primary_location(f),
                f.get("impact", "?"),
                " ".join((f.get("description") or "").split())[:160],
            )
            for f in load_findings(args.slither_json)
        ]
        if args.aderyn is not None:
            findings += [("aderyn", *f) for f in load_aderyn(args.aderyn)]
    except TriageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if problems:
        print("error: the triage file is malformed, so it cannot gate anything:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 2

    exact = {(r["tool"], r["detector"], r["location"]): r for r in rows}
    by_file = {
        (r["tool"], r["detector"], r["location"]): r for r in rows if ":" not in r["location"]
    }
    matched: set[tuple[str, str, str]] = set()

    untriaged: list[tuple[str, str, str, str, str]] = []
    broad: list[str] = []
    for tool, detector, location, impact, description in findings:
        key = (tool, detector, location)
        file_key = (tool, detector, location.rsplit(":", 1)[0])
        if key in exact:
            matched.add(key)
        elif file_key in by_file:
            matched.add(file_key)
            broad.append(
                f"{tool} {detector} at {location} is covered by a whole-file row for "
                f"{file_key[2]} — narrow it to file:line once the code settles"
            )
        else:
            untriaged.append((tool, detector, location, impact, description))

    gated = {"slither"} | ({"aderyn"} if args.aderyn is not None else set())
    stale = [
        r
        for r in rows
        if r["tool"] in gated and (r["tool"], r["detector"], r["location"]) not in matched
    ]

    for note in broad:
        print(f"notice: {note}")
    for row in stale:
        print(
            f"notice: {args.triage_md.name}:{row['_line']}: row {row['id'] or '?'} "
            f"({row['detector']} at {row['location']}) matches no current finding — "
            "remove it once the fix is confirmed"
        )

    tools = " + ".join(sorted(gated))
    print(
        f"{tools} findings: {len(findings)}; triaged rows: {len(rows)}; untriaged: {len(untriaged)}"
    )

    if not untriaged:
        print(f"OK: every {tools} finding is accounted for in the triage file.")
        return 0

    print("", file=sys.stderr)
    print(
        f"error: {len(untriaged)} finding(s) are not in {args.triage_md}. "
        "Fix them, or add a row with a real justification:",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    for tool, detector, location, impact, description in untriaged:
        print(f"| ? | {tool} | {detector} | {location} | {impact} | ? | ? | ? |", file=sys.stderr)
        print(f"      {description}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
