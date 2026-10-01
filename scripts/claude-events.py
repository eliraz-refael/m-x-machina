#!/usr/bin/env python3
"""Observe Claude hooks without changing permissions, context, or rendered text."""
import fcntl
import json
import os
import sys


def main():
    incoming = json.load(sys.stdin)
    # Keep event metadata only, never prompts, tool payloads, or response text.
    fields = ("hook_event_name", "session_id", "agent_id", "notification_type",
              "tool_name", "model", "to_model", "error")
    event = {key: incoming[key] for key in fields if isinstance(incoming.get(key), str)}
    event["has_message"] = bool(incoming.get("delta") or incoming.get("last_assistant_message"))
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        output.write(json.dumps(event, ensure_ascii=True) + "\n")
        output.flush()
    # Empty stdout leaves all permission decisions and display text untouched.


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, IndexError) as error:
        print(f"Emacs Agents event hook: {error}", file=sys.stderr)
        sys.exit(1)
