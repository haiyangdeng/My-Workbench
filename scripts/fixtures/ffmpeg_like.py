#!/usr/bin/python3 -I
# Test stand-in for ffmpeg in command steps: "-i FILE" inputs are concatenated into the last argument.
import json, os, sys, time

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
if args[:1] == ["-version"] or args[:1] == ["--version"]:
    print("ffmpeg-like 1.0 (fixture)"); sys.exit(0)
inputs = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-i"]
target = args[-1]
with open(target, "wb") as out:
    for path in inputs:
        with open(path, "rb") as f:
            out.write(f.read())
with open(os.path.join(here, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": args, "time": time.time()}) + "\n")
print("joined %d inputs into %s" % (len(inputs), os.path.basename(target)))
