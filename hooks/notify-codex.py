#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 2:
        return 0

    try:
        event = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return 0

    if event.get("type") != "agent-turn-complete":
        return 0

    cwd = event.get("cwd") or ""
    project = os.path.basename(cwd) or "Codex"
    title = f"Codex CLI · {project}"

    message = "Turn complete"
    last_assistant = event.get("last_assistant_message") or {}
    content = last_assistant.get("content")
    if isinstance(content, str) and content.strip():
        message = content.strip().splitlines()[0][:160]

    notify_path = os.path.expanduser("~/.codex/hooks/notify.sh")
    if not os.path.exists(notify_path):
        return 0

    subprocess.run([notify_path, title, message], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
