#!/usr/bin/env python3
"""PreToolUse guard: block edits to protected paths. Exit 2 blocks the tool call."""
import fnmatch
import json
import os
import sys

ALWAYS = [".claude/settings.json", ".claude/hooks/*", ".claude/protected-paths.txt",
          ".env", ".env.*", "*/.env", "*/.env.*", "data/raw/**", "deployments/**"]


def load_patterns(root):
    pats = list(ALWAYS)
    try:
        with open(os.path.join(root, ".claude", "protected-paths.txt"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    pats.append(line)
    except FileNotFoundError:
        pass
    return pats


def matches(rel, pattern):
    pattern = pattern.rstrip("/")
    if pattern.endswith("/**"):
        base = pattern[:-3]
        return rel == base or rel.startswith(base + "/")
    return fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(rel, pattern.replace("**/", ""))


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    tool_input = data.get("tool_input") or {}
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path:
        return 0
    root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root)).replace(os.sep, "/")
    if rel.startswith(".."):
        print(f"BLOCKED: {path} is outside the project. Edits outside the repo are not allowed.",
              file=sys.stderr)
        return 2
    for pat in load_patterns(root):
        if matches(rel, pat):
            print(f"BLOCKED: '{rel}' is protected (pattern '{pat}'). Do not work around this. "
                  "If a change is genuinely required, stop and use /spec-change or ask the human "
                  "to unlock it in .claude/protected-paths.txt.", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
