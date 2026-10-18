#!/usr/bin/python3 -I
# Test fixture that speaks Claude Code's headless stream-json. It never calls a model.
# Sessions live in ./state/sessions so --resume can recall earlier prompts.
import json, os, sys, time

here = os.path.dirname(os.path.abspath(__file__))
state = os.path.join(here, "state")
os.makedirs(os.path.join(state, "sessions"), exist_ok=True)
args = sys.argv[1:]
start = time.time()


def opt(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def emit(value):
    print(json.dumps(value), flush=True)


def record(kind, extra=None):
    entry = {"cli": "claude", "kind": kind, "argv": args, "cwd": os.getcwd(), "start": start, "end": time.time()}
    entry.update(extra or {})
    with open(os.path.join(state, "calls.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")


if args[:1] == ["--version"]:
    version_file = os.path.join(state, "version")
    print(open(version_file).read().strip() if os.path.exists(version_file) else "claude-like 1.0 (fixture)"); sys.exit(0)
if args[:2] == ["auth", "status"]:
    ok = not os.path.exists(os.path.join(state, "logged-out"))
    print(json.dumps({"loggedIn": ok}, indent=2)); sys.exit(0 if ok else 1)
if "-p" not in args and "--resume" in args:
    # Interactive resume in the built-in terminal.
    print("interactive resume " + opt("--resume"), flush=True)
    sys.stdin.readline()
    record("interactive")
    sys.exit(0)
if os.path.exists(os.path.join(state, "logged-out")):
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "Not logged in · Please run /login"})
    record("logged-out"); sys.exit(1)

prompt = opt("-p") or ""
resume = opt("--resume")
session = opt("--session-id") or resume or "no-session"
path = os.path.join(state, "sessions", session + ".json")
if resume:
    if not os.path.exists(path):
        print("No conversation found with session ID: " + resume, file=sys.stderr)
        record("missing-session"); sys.exit(1)
    history = json.load(open(path))
else:
    history = []
history.append(prompt)
json.dump(history, open(path, "w"))
emit({"type": "system", "subtype": "init", "session_id": session})
mode = opt("--permission-mode")

if "SLOW" in prompt:
    for i in range(48):
        emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "tick %d " % i}}, "session_id": session})
        time.sleep(0.25)
if "STREAM" in prompt:
    for i in range(20):
        emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "word%d " % i}}, "session_id": session})
        time.sleep(0.15)

reply = "turn %d of %s; first message was: %s" % (len(history), session, history[0].split("\n")[-1][:120])
if mode == "acceptEdits":
    target = os.path.join(os.getcwd(), "edited-by-claude.txt")
    with open(target, "a") as f:
        f.write("edit\n")
    emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {"file_path": target}}]}, "session_id": session})
emit({"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}, "session_id": session})
result = {"type": "result", "subtype": "success", "is_error": False, "result": reply, "session_id": session,
          "total_cost_usd": 0.001, "usage": {"input_tokens": len(prompt), "output_tokens": 9}}
if "NEEDS-APPROVAL" in prompt and mode != "acceptEdits":
    result["permission_denials"] = [{"tool_name": "Bash", "tool_use_id": "t1", "tool_input": {"command": "make deploy"}}]

schema = opt("--json-schema")
if schema:
    import re
    properties = json.loads(schema).get("properties", {})
    if "steps" in properties and "templateID" in properties["steps"]["items"]["properties"]:
        # Director: read the catalog from the prompt and plan keyframe -> animation, a voice line, then a join.
        templates = dict((name.strip(), id) for id, name in re.findall(r"模板 id=([0-9A-F-]{36})：([^（\n]+)", prompt))
        servers = re.findall(r"服务器 id=([0-9A-F-]{36})：", prompt)
        staff = dict((name.strip(), id) for id, name in re.findall(r"员工 id=([0-9A-F-]{36})：([^（\n]+)", prompt))
        tools = re.findall(r"命令工具 id=([0-9A-F-]{36})：", prompt)
        def step(id, title, kind, deps=(), template="", parameters=(), inputs=(), tool="", arguments=(), employee="", text="", access="readOnly"):
            return {"id": id, "title": title, "kind": kind, "employeeID": employee or staff.get("Director", ""), "input": text or title, "acceptance": title + " looks right",
                    "dependencies": list(deps), "access": access, "templateID": templates.get(template, ""), "serverID": servers[0] if kind == "generate" else "",
                    "parameters": [{"name": n, "value": v} for n, v in parameters], "inputs": [{"name": n, "value": v} for n, v in inputs],
                    "toolID": tool, "arguments": list(arguments)}
        steps = [
            step("script", "Write the shot list", "agent", text="Write a 3-shot list for the teaser"),
            step("key1", "Keyframe for shot 1", "generate", template="Keyframe t2i", parameters=[("prompt", "a city at dawn, wide shot"), ("seed", "random")], inputs=[("image", "attachment:0")]),
            step("voice", "Narration line", "generate", template="Voice tts", parameters=[("text", "Every city wakes up differently.")]),
            step("anim", "Animate shot 1", "generate", deps=["key1"], template="Animate i2v", parameters=[("frames", "48")], inputs=[("image", "step:key1")]),
            step("join", "Join clip and narration", "command", deps=["anim", "voice"], tool=tools[0] if tools else "", arguments=["-i", "{input:anim}", "-i", "{input:voice}", "{output}/final.mp4"]),
        ]
        result["structured_output"] = {"title": "Teaser production", "goal": "20-second teaser", "steps": steps}
        result["result"] = json.dumps(result["structured_output"])
    elif "decision" in properties and "parameters" in properties:
        marker = os.path.join(state, "media-reworked")
        if "image-1." in prompt and "Keyframe" in prompt and not os.path.exists(marker):
            open(marker, "w").close()
            result["structured_output"] = {"decision": "rework", "notes": "Saw image-1.png; the horizon is crooked. Trying another seed.", "parameters": [{"name": "seed", "value": "1234"}]}
        elif "keyframe" in prompt:
            result["structured_output"] = {"decision": "pass", "notes": "Checked 4 keyframes and the metadata; motion between frames not verified.", "parameters": []}
        elif "无法听到" in prompt:
            result["structured_output"] = {"decision": "pass", "notes": "Audio metadata only (duration and sample rate); did not listen.", "parameters": []}
        else:
            result["structured_output"] = {"decision": "pass", "notes": "Saw image-1.png; composition matches the request.", "parameters": []}
    elif "steps" in properties:
        ids = properties["steps"]["items"]["properties"]["employeeID"]["enum"]
        lead, worker = ids[0], ids[-1]
        if "INVALID-PLAN" in prompt and "上一次返回的计划不能使用" not in prompt:
            steps = [{"id": "a", "title": "Loop", "employeeID": worker, "input": "x", "acceptance": "x", "dependencies": ["a"], "access": "edit"}]
        elif "WORKTREE-PAIR" in prompt:
            steps = [{"id": "w1", "title": "Edit in worktree 1", "employeeID": worker, "input": "LOCKTEST worktree one", "acceptance": "written", "dependencies": [], "access": "edit"},
                     {"id": "w2", "title": "Edit in worktree 2", "employeeID": worker, "input": "LOCKTEST worktree two", "acceptance": "written", "dependencies": [], "access": "edit"}]
        elif "READONLY-PAIR" in prompt:
            steps = [{"id": "r1", "title": "Read part 1", "employeeID": worker, "input": "LOCKTEST read 1", "acceptance": "notes", "dependencies": [], "access": "readOnly"},
                     {"id": "r2", "title": "Read part 2", "employeeID": worker, "input": "LOCKTEST read 2", "acceptance": "notes", "dependencies": [], "access": "readOnly"}]
        elif "REVIEW-PLAN" in prompt:
            steps = [{"id": "w", "title": "Implement with review", "employeeID": worker, "input": "REWORK-ME implement the change", "acceptance": "change made", "dependencies": [], "access": "edit"}]
        else:
            steps = [{"id": "a", "title": "Edit part A", "employeeID": worker, "input": "LOCKTEST edit A", "acceptance": "A written", "dependencies": [], "access": "edit"},
                     {"id": "b", "title": "Edit part B", "employeeID": worker, "input": "LOCKTEST edit B", "acceptance": "B written", "dependencies": [], "access": "edit"},
                     {"id": "c", "title": "Check both parts", "employeeID": lead, "input": "check A and B", "acceptance": "checked", "dependencies": ["a", "b"], "access": "readOnly"}]
        result["structured_output"] = {"title": "Fixture team plan", "goal": "verify team mode", "steps": steps}
        result["result"] = json.dumps(result["structured_output"])
    elif "decision" in properties:
        marker = os.path.join(state, "reworked-once")
        if "REWORK-ME" in prompt and not os.path.exists(marker):
            open(marker, "w").close()
            result["structured_output"] = {"decision": "rework", "notes": "fixture asks for one more pass"}
        else:
            result["structured_output"] = {"decision": "pass", "notes": "fixture checked the archived text"}
record("turn", {"session": session, "mode": mode, "prompt": prompt[:200]})
emit(result)
