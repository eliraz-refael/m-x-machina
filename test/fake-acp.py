"""Offline ACP fixture: durable conversation IDs and deterministic replies.

Not a coding agent. Uses only Python's standard library and local files.
"""
import json
from pathlib import Path
import sys
import uuid
import time
import re
import select

storage = Path(sys.argv[1])
storage.mkdir(parents=True, exist_ok=True)
mode = sys.argv[2] if len(sys.argv) > 2 else "normal"
model_info = {"currentModelId": "offline-fixture", "availableModels": [
    {"modelId": "offline-fixture", "name": "Offline fixture", "description": "Local deterministic demo"}]}


def emit(value):
    print(json.dumps(value), flush=True)


def emit_text(session_id, text):
    emit({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session_id, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def work_for(session_id, seconds):
    """Wait without blocking ACP cancellation; return False when cancelled."""
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        if not select.select([sys.stdin], [], [], remaining)[0]:
            break
        line = sys.stdin.readline()
        if not line:
            raise SystemExit(0)
        request = json.loads(line)
        if (request.get("method") == "session/cancel"
                and request.get("params", {}).get("sessionId") == session_id):
            if "id" in request:
                emit({"jsonrpc": "2.0", "id": request["id"], "result": {}})
            return False
        if "id" in request:
            emit({"jsonrpc": "2.0", "id": request["id"], "error": {
                "code": -32000, "message": "Mock is working; cancel it before sending another request"}})
    return True


def respond(request):
    method = request["method"]
    params = request.get("params", {})
    with (storage / "requests.jsonl").open("a") as log:
        log.write(json.dumps({"method": method, "params": params}) + "\n")
    if method == "initialize":
        return {"protocolVersion": 1,
                "agentCapabilities": {"loadSession": mode != "unsupported"},
                "authMethods": []}
    if method == "session/new":
        sid = uuid.uuid4().hex
        (storage / f"{sid}.json").write_text(json.dumps({"cwd": params["cwd"], "turns": 0}))
        return {"sessionId": sid, "models": model_info}
    if method == "session/load":
        data = json.loads((storage / f"{params['sessionId']}.json").read_text())
        if data["cwd"] != params["cwd"]:
            raise ValueError("Wrong worktree for this conversation")
        if data["turns"]:
            emit_text(params["sessionId"], f"Restored history: {data['turns']} previous turns.")
        return {"models": model_info}
    if method == "session/prompt":
        prompt = " ".join(block.get("text", "") for block in params.get("prompt", [])
                          if block.get("type") == "text").strip()
        simulation = re.fullmatch(r"/work(?:\s+(\d+))?", prompt)
        seconds = int(simulation.group(1) or 20) if simulation else 0.8
        if prompt.startswith("/work") and (not simulation or not 1 <= seconds <= 300):
            raise ValueError("Use /work or /work SECONDS (1–300)")
        if simulation:
            emit_text(params["sessionId"], f"Simulating work for {seconds} seconds…\n")
        if not work_for(params["sessionId"], seconds):
            emit_text(params["sessionId"], "Simulation cancelled.\n")
            return {"stopReason": "cancelled"}
        file = storage / f"{params['sessionId']}.json"
        data = json.loads(file.read_text())
        data["turns"] += 1
        file.write_text(json.dumps(data))
        emit_text(params["sessionId"], f"Offline demo reply {data['turns']}. Conversation: {params['sessionId']}")
        return {"stopReason": "end_turn"}
    if method == "session/cancel":
        return {}
    raise ValueError(f"Unsupported method: {method}")


for line in sys.stdin:
    request = json.loads(line)
    if "method" not in request:
        continue
    try:
        result = respond(request)
        if "id" in request:
            emit({"jsonrpc": "2.0", "id": request["id"], "result": result})
    except Exception as error:
        if "id" in request:
            emit({"jsonrpc": "2.0", "id": request["id"], "error": {
                "code": -32000, "message": str(error)}})
