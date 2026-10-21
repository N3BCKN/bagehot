#!/usr/bin/env python3
"""PreToolUse guard for Bash: block secret access and broadcasts to non-allowed networks.
Defence in depth on top of permission rules. Exit 2 blocks the command."""
import json
import re
import sys

LOCAL = re.compile(r"(127\.0\.0\.1|localhost|0\.0\.0\.0|anvil)", re.I)
SEPOLIA_ALIAS = re.compile(r"(base_sepolia|BASE_SEPOLIA_RPC|sepolia)", re.I)


def block(msg):
    print("BLOCKED: " + msg, file=sys.stderr)
    sys.exit(2)


def rpc_target(cmd):
    m = re.search(r"--(?:rpc-url|fork-url|rpc)[ =](\S+)", cmd)
    return m.group(1) if m else ""


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    cmd = (data.get("tool_input") or {}).get("command", "") or ""
    flat = " ".join(cmd.split())

    secret_patterns = [r"\.env\b", r"keystores?", r"\bmnemonic\b", r"PRIVATE_KEY", r"\.ssh/",
                       r"cast wallet (?:decrypt|private-key|derive)"]
    if re.search(r"\b(cat|less|more|head|tail|bat|grep|rg|sed|awk|cp|mv|echo|printenv|env)\b", flat):
        for pat in secret_patterns:
            if re.search(pat, flat):
                block("this command may expose secrets (.env, keystores, private keys). "
                      "Ask the human instead.")
    if re.search(r"--private-key\b", flat) and not LOCAL.search(rpc_target(flat) or flat):
        block("--private-key is only allowed against local anvil. Use --account <keystore> on "
              "testnets, and let the human run the broadcast.")
    if re.search(r"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|python)", flat):
        block("piping downloaded content into a shell is forbidden.")
    if re.search(r"git push\b.*(--force|-f\b|--force-with-lease)", flat):
        block("force-push is forbidden.")

    broadcasting = ("--broadcast" in flat) or re.search(r"\bcast (send|publish)\b", flat)
    if broadcasting:
        target = rpc_target(flat)
        if not target:
            block("broadcast without an explicit --rpc-url. State the target network explicitly.")
        if LOCAL.search(target):
            return 0
        if SEPOLIA_ALIAS.search(target):
            if "--account" not in flat:
                block("Base Sepolia broadcasts must use --account <keystore-name>.")
            return 0
        block(f"broadcast to '{target}' is not allowed. Only local anvil and Base Sepolia are "
              "permitted; Base and Ethereum mainnet are read-only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
