#!/usr/bin/env python3
"""PostToolUse: format the edited file. Never blocks; failures are reported to stderr only."""
import json
import os
import subprocess
import sys


def run(cmd, cwd):
    try:
        subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       timeout=60, check=False)
    except Exception as exc:  # formatting must never break the session
        print(f"format hook skipped: {exc}", file=sys.stderr)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    path = (data.get("tool_input") or {}).get("file_path") or ""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if path.endswith(".sol") and os.path.isdir(os.path.join(root, "contracts")):
        run(["forge", "fmt", os.path.abspath(path)], os.path.join(root, "contracts"))
    elif path.endswith(".py"):
        run(["uv", "run", "ruff", "format", "--quiet", os.path.abspath(path)], root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
