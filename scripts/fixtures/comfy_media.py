#!/usr/bin/python3 -I
"""Local ComfyUI-compatible test server for M8. It never generates anything: outputs are files from the
media folder given on the command line (image.png, clip.mp4, tone.wav). Pass --no-jobs to imitate an old
server without the single-job cancel API. Binds to 127.0.0.1 only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os, re, sys, threading

media = sys.argv[1]
no_jobs = "--no-jobs" in sys.argv
jobs, prompts, uploads, requests = {}, [], [], []
lock = threading.Lock()
outputs_by_class = {"SaveImage": ("images", "image.png"), "VHS_VideoCombine": ("gifs", "clip.mp4"), "SaveAudio": ("audio", "tone.wav")}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data, status=200):
        payload = json.dumps(data).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(payload))); self.end_headers()
        self.wfile.write(payload)

    def file_for(self):
        match = re.search(r"filename=([^&]+)", self.path)
        name = os.path.basename(match.group(1)) if match else ""
        path = os.path.join(media, name)
        return path if os.path.isfile(path) else None

    def do_HEAD(self):
        with lock: requests.append(["HEAD", self.path])
        path = self.file_for() if self.path.startswith("/view?") else None
        if not path:
            return self.send_error(404)
        self.send_response(200); self.send_header("Content-Length", str(os.path.getsize(path))); self.end_headers()

    def do_GET(self):
        with lock: requests.append(["GET", self.path])
        if self.path.startswith("/system_stats"):
            return self.reply({"system": {"comfyui_version": "fixture-0.3"}, "devices": [{"name": "cuda:0 Fixture GPU", "vram_total": 25769803776, "vram_free": 20000000000}]})
        if self.path.startswith("/object_info"):
            known = ["KSampler", "CLIPTextEncode", "LoadImage", "SaveImage", "WanImageToVideo", "VHS_VideoCombine", "TTSNode", "SaveAudio", "EmptyLatentImage"]
            return self.reply({name: {"input": {}, "output": []} for name in known})
        if self.path.startswith("/api/jobs"):
            return self.reply({"error": "not found"}, 404) if no_jobs else self.reply({"jobs": []})
        if self.path == "/fixture/report":
            with lock: return self.reply({"prompts": prompts, "uploads": uploads, "requests": requests})
        if self.path.startswith("/view?"):
            path = self.file_for()
            if not path:
                return self.send_error(404)
            data = open(path, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path.startswith("/history/"):
            id = self.path.rsplit("/", 1)[-1]
            with lock:
                job = jobs.get(id)
                if not job:
                    return self.reply({})
                job["polls"] += 1
                if job["cancelled"]:
                    return self.reply({id: {"status": {"completed": False, "status_str": "error", "messages": [["execution_interrupted", {}]]}, "outputs": {}}})
                if job["polls"] < job["needed"]:
                    return self.reply({})
                return self.reply({id: {"status": {"completed": True, "status_str": "success"}, "outputs": job["outputs"]}})
        if self.path == "/queue":
            with lock:
                pending = [[1, id, {}] for id, job in jobs.items() if not job["cancelled"] and job["polls"] < job["needed"]]
            return self.reply({"queue_running": [], "queue_pending": pending})
        self.reply({"error": "not found"}, 404)

    def do_POST(self):
        with lock: requests.append(["POST", self.path])
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/upload/image":
            match = re.search(rb'name="image"; filename="([^"]+)"', body)
            name = match.group(1).decode() if match else "upload.bin"
            with lock: uploads.append({"name": name, "bytes": len(body)})
            return self.reply({"name": name, "subfolder": "workbench", "type": "input"})
        data = json.loads(body or b"{}")
        if self.path == "/prompt":
            workflow = data["prompt"]; id = data["prompt_id"]
            outputs = {}
            slow = False
            for node_id, node in workflow.items():
                kind = outputs_by_class.get(node.get("class_type"))
                if kind:
                    outputs[node_id] = {kind[0]: [{"filename": kind[1], "subfolder": "", "type": "output"}]}
                if any(isinstance(v, str) and "SLOW" in v for v in node.get("inputs", {}).values()):
                    slow = True
            with lock:
                prompts.append({"id": id, "workflow": workflow})
                jobs[id] = {"polls": 0, "needed": 30 if slow else 2, "cancelled": False, "outputs": outputs}
            return self.reply({"prompt_id": id})
        if self.path.startswith("/api/jobs/") and self.path.endswith("/cancel"):
            id = self.path.split("/")[3]
            with lock:
                job = jobs.get(id)
                changed = bool(job and not job["cancelled"] and job["polls"] < job["needed"])
                if changed:
                    job["cancelled"] = True
            return self.reply({"cancelled": changed})
        self.reply({"error": "unexpected"}, 404)


def watch_parent(parent=os.getppid()):
    # Exit with the test harness, even if it stops without cleaning up.
    import time
    while os.getppid() == parent:
        time.sleep(0.5)
    os._exit(0)


threading.Thread(target=watch_parent, daemon=True).start()
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(f"http://127.0.0.1:{server.server_port}", flush=True)
server.serve_forever()
