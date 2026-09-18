"""Offline ACP fixture: durable conversation IDs and deterministic replies.

Not a coding agent. Uses only Python's standard library and local files.
"""
import json
from pathlib import Path
import sys
import uuid

storage = Path(sys.argv[1])
storage.mkdir(parents=True, exist_ok=True)
mode = sys.argv[2] if len(sys.argv) > 2 else "normal"


def emit(value):
    print(json.dumps(value), flush=True)


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
        return {"sessionId": sid}
    if method == "session/load":
        data = json.loads((storage / f"{params['sessionId']}.json").read_text())
        if data["cwd"] != params["cwd"]:
            raise ValueError("Wrong worktree for this conversation")
        return {}
    if method == "session/prompt":
        file = storage / f"{params['sessionId']}.json"
        data = json.loads(file.read_text())
        data["turns"] += 1
        file.write_text(json.dumps(data))
        emit({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": params["sessionId"], "update": {
                "sessionUpdate": "agent_message_chunk", "content": {
                    "type": "text", "text": f"Offline demo reply {data['turns']}. Conversation: {params['sessionId']}"}}}})
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
