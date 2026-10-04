#!/usr/bin/env python3
"""Offline interactive CLI fixture exercising actual EAT and Claude hook scripts."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import re
import select
import termios
import tty

parser = argparse.ArgumentParser()
parser.add_argument("--settings", required=True)
identity = parser.add_mutually_exclusive_group(required=True)
identity.add_argument("--resume")
identity.add_argument("--session-id")
args = parser.parse_args()
hooks = json.loads(Path(args.settings).read_text())["hooks"]
sid = args.resume or args.session_id
store = Path(os.environ["FAKE_CLAUDE_STORE"])
store.mkdir(parents=True, exist_ok=True)
with (store / "launches.jsonl").open("a") as output:
    output.write(json.dumps({"resume": args.resume, "new": args.session_id,
                             "cwd": os.getcwd(), "account": os.environ.get("CLAUDE_CONFIG_DIR")}) + "\n")
history = store / (sid + ".json")
if args.resume and not history.exists():
    print("Cannot find requested conversation", flush=True)
    sys.exit(3)
turns = json.loads(history.read_text()) if history.exists() else 0


def save():
    history.write_text(json.dumps(turns))


def hook(name, **fields):
    data = dict(hook_event_name=name, session_id=sid, cwd=os.getcwd(), **fields)
    for entry in hooks.get(name, []):
        for handler in entry["hooks"]:
            result = subprocess.run(handler["command"], shell=True, input=json.dumps(data),
                                    text=True, capture_output=True, timeout=5)
            if result.returncode or result.stdout:
                raise RuntimeError("Hook must succeed without modifying Claude output: " + result.stderr)


def reply(text=None):
    global turns
    turns += 1
    text = text or f"Terminal reply {turns}"
    save()
    hook("MessageDisplay", delta=text, index=0, final=True)
    print(f"\033[32m{text}\033[0m", flush=True)
    hook("Stop", last_assistant_message=text)


def fullscreen():
    "Stream into a virtualized alternate screen, like Claude's fullscreen UI."
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    total, top, following = 80, 70, True
    pending = b""
    tick = time.monotonic()
    print("\033[?1049h\033[?1000h\033[?1006h", end="", flush=True)
    try:
        while True:
            if time.monotonic() - tick > 0.15:
                total += 1
                tick = time.monotonic()
                if following:
                    top = total - 10
            screen = [f"History row {i:04d}" for i in range(top, top + 10)]
            screen += [f"STREAM COUNT {total:04d}", "Prompt remains visible"]
            print("\033[H" + "\r\n".join(line + "\033[K" for line in screen)
                  + "\033[J", end="", flush=True)
            if not select.select([fd], [], [], 0.03)[0]:
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            pending += chunk
            while pending:
                match = re.match(rb"\x1b\[(?:[0-9;]*[~HF]|<[0-9;]+[Mm])", pending)
                if not match:
                    if pending.startswith(b"\x1b") and len(pending) < 32:
                        break
                    pending = pending[1:]
                    continue
                key = match.group()
                pending = pending[len(key):]
                if key == b"\x1b[5~" or key.startswith(b"\x1b[<64;"):
                    top, following = max(0, top - 5), False
                elif key == b"\x1b[6~" or key.startswith(b"\x1b[<65;"):
                    top = min(total - 10, top + 5)
                elif key in (b"\x1b[1;5H", b"\x1b[1;5~", b"\x1b[7;5~"):
                    top, following = 0, False
                elif key in (b"\x1b[1;5F", b"\x1b[4;5~", b"\x1b[8;5~"):
                    top, following = total - 10, True
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)


save()
hook("SessionStart", source="resume" if args.resume else "startup", model="offline-terminal-model")
print(f"\033[34mOffline Claude terminal\033[0m. History: {turns}", flush=True)
for line in sys.stdin:
    line = line.strip()
    if line == "/fullscreen":
        hook("UserPromptSubmit", prompt=line)
        fullscreen()
        break
    if line == "/long":
        print("\n".join(f"Long row {i:04d} " + "x" * 70 for i in range(4000)), flush=True)
        continue
    if line == "/exit":
        hook("SessionEnd")
        break
    if line == "/replace":
        sid = "different-conversation"
        hook("SessionStart", source="clear")
        continue
    if line == "/redraw":
        print(f"\033[2J\033[HHistory: {turns}", flush=True)
        continue
    if line == "/approve":
        hook("PostToolUse", tool_name="Bash")
        reply()
        continue
    if line == "/model":
        hook("PostModelSwitch", to_model="offline-terminal-model-2")
        continue
    hook("UserPromptSubmit", prompt=line)
    if line == "/ask":
        hook("PreToolUse", tool_name="Bash")
        hook("PermissionRequest", tool_name="Bash")
        print("Approve? Type /approve", flush=True)
        continue
    if line.startswith(("/peer ", "/peer-no-identity ")):
        environment = os.environ.copy()
        if line.startswith("/peer-no-identity "):
            environment.pop("EMACS_AGENTS_ID", None)
        identity = subprocess.run([os.environ["EMACS_AGENTS_CLI"], "whoami"],
                                  env=environment, capture_output=True, text=True, timeout=10)
        if identity.returncode:
            raise RuntimeError(identity.stderr)
        print("Identity: " + json.loads(identity.stdout)["id"], flush=True)
        result = subprocess.run([os.environ["EMACS_AGENTS_CLI"], "send", line.split(" ", 1)[1],
                                 "Please answer your peer", "--wait", "--timeout", "8"],
                                env=environment, capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        reply("Peer replied: " + json.loads(result.stdout)["response"])
        continue
    if line.startswith("/work"):
        time.sleep(float(line.split()[1]) if len(line.split()) > 1 else 1)
    reply()
