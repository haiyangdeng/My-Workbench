#!/usr/bin/python3 -I
# Test fixture that speaks Codex's `exec --json` JSONL. It never calls a model.
import json, os, sys, time, uuid

here = os.path.dirname(os.path.abspath(__file__))
state = os.path.join(here, "state")
os.makedirs(state, exist_ok=True)
args = sys.argv[1:]
start = time.time()


def opt(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def emit(value):
    print(json.dumps(value), flush=True)


if args[:1] == ["--version"]:
    print("codex-like 1.0 (fixture)"); sys.exit(0)
if args[:2] == ["login", "status"]:
    print("Logged in using fixture"); sys.exit(0)

prompt = args[args.index("--") + 1] if "--" in args else (args[-1] if args else "")
thread = args[3] if args[:2] == ["exec", "resume"] and len(args) > 3 else str(uuid.uuid4())
sandbox = opt("--sandbox")
emit({"type": "thread.started", "thread_id": thread})
emit({"type": "turn.started"})
if "LOCKTEST" in prompt:
    # Worktree steps start only after git creates their worktree, so they need a longer window to overlap.
    time.sleep(4 if "worktree" in prompt else 1.5)
if sandbox == "workspace-write":
    with open(os.path.join(os.getcwd(), "edited-by-codex.txt"), "a") as f:
        f.write(prompt.split("\n")[0][:80] + "\n")
    emit({"type": "item.completed", "item": {"id": "i1", "type": "file_change", "changes": [{"path": "edited-by-codex.txt", "kind": "update"}]}})
emit({"type": "item.completed", "item": {"id": "i2", "type": "command_execution", "command": "ls", "status": "completed"}})
emit({"type": "item.completed", "item": {"id": "i3", "type": "agent_message", "text": "codex did: " + prompt.split("\n")[-1][:80]}})
emit({"type": "turn.completed", "usage": {"input_tokens": len(prompt), "output_tokens": 5}})
with open(os.path.join(state, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"cli": "codex", "argv": args, "sandbox": sandbox, "prompt": prompt[:200], "cwd": os.getcwd(), "start": start, "end": time.time()}) + "\n")
