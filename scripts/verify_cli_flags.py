#!/usr/bin/python3 -I
"""Checks every flag, subcommand and option value used in docs/cli-examples against the installed CLI's own help
output, and runs the free version and login-status commands. No model is called and nothing is configured.
A CLI that is not installed is reported and skipped."""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = os.path.join(ROOT, "docs", "cli-examples")
# Help pages that document each definition's flags, plus the values its options take.
HELP = {
    "claude-code.json": {"pages": [["--help"], ["auth", "--help"]], "words": ["plan", "acceptEdits", "stream-json", "status", "login"]},
    "codex.json": {"pages": [["--help"], ["exec", "--help"], ["exec", "resume", "--help"], ["login", "--help"]],
                   "words": ["read-only", "workspace-write", "resume", "status", "exec"]},
}
TEMPLATES = ["arguments", "resumeArguments", "interactiveResumeArguments", "readOnlyArguments", "editArguments",
             "structuredOutputArguments", "modelArguments", "versionArguments", "loginStatusArguments", "loginArguments"]


def login_shell(command):
    shell = os.environ.get("SHELL", "/bin/zsh")
    return subprocess.run([shell, "-l", "-c", command], capture_output=True, text=True, timeout=30)


failed = False
for name, spec in HELP.items():
    tool = json.load(open(os.path.join(EXAMPLES, name)))["tool"]
    found = login_shell("command -v " + tool["executable"]).stdout.strip().splitlines()
    if not found:
        print(f"SKIP {name}: `{tool['executable']}` is not installed")
        continue
    path = found[-1]
    def run(args):
        result = login_shell(" ".join([path] + ["'" + a.replace("'", "'\\''") + "'" for a in args]))
        return result.returncode, result.stdout + result.stderr
    help_text = "\n".join(run(page)[1] for page in spec["pages"])
    flags = sorted({token for key in TEMPLATES for token in tool.get(key) or [] if token.startswith("--") and token != "--"})
    missing = [flag for flag in flags if not re.search(re.escape(flag) + r"\b", help_text)]
    missing += [word for word in spec["words"] if word not in help_text]
    code, version = run(tool.get("versionArguments") or ["--version"])
    code, status = run(tool["loginStatusArguments"])
    state = "logged out" if tool.get("loggedOutText") and tool["loggedOutText"] in status else ("logged in" if code == 0 else "check failed")
    if missing:
        failed = True
        print(f"FAIL {name}: not in `{os.path.basename(path)}` help: {', '.join(missing)}")
    else:
        print(f"PASS {name}: {len(flags)} flags and {len(spec['words'])} option values found in the help of {path} ({version.strip().splitlines()[0] if version.strip() else 'no version'}); login: {state}")
sys.exit(1 if failed else 0)
