"""Local HTTP contract fixture; does not perform image generation or connect to remote hosts."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, threading

jobs = {}
lock = threading.Lock()
requests = []
other = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
content = 'ComfyUI contract fixture 中文\n'.encode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, data, status=200):
        payload = json.dumps(data).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(payload))); self.end_headers()
        self.wfile.write(payload)
    def record(self):
        with lock: requests.append([self.command, self.path])
    def do_HEAD(self):
        self.record()
        if self.path.startswith('/view?'):
            self.send_response(200); self.send_header('Content-Length', str(len(content))); self.end_headers()
        else: self.send_error(404)
    def do_GET(self):
        self.record()
        if self.path.startswith('/system_stats'): return self.reply({'system': {'comfyui_version': 'fixture'}})
        if self.path.startswith('/api/jobs?'): return self.reply({'jobs': [], 'pagination': {'total': 0}})
        if self.path == '/fixture/report': return self.reply({'requests': requests, 'other_active': True})
        if self.path.startswith('/view?'):
            self.send_response(200); self.send_header('Content-Length', str(len(content))); self.end_headers(); self.wfile.write(content); return
        if self.path.startswith('/history/'):
            id = self.path.rsplit('/', 1)[-1]
            with lock:
                job = jobs.get(id)
                if not job: return self.reply({})
                job['polls'] += 1
                if job['cancelled']: return self.reply({id: {'status': {'completed': False, 'status_str': 'error', 'messages': [['execution_interrupted', {}]]}, 'outputs': {}}})
                if job['mode'] == 'cancel' or job['polls'] < 2: return self.reply({})
                return self.reply({id: {'status': {'completed': True, 'status_str': 'success'}, 'outputs': {'1': {'texts': [{'filename': 'result.txt', 'subfolder': 'fixture', 'type': 'output'}]}}}})
        if self.path == '/queue':
            with lock:
                pending = [[1, id, {}] for id, job in jobs.items() if not job['cancelled'] and (job['mode'] == 'cancel' or job['polls'] < 2)]
            return self.reply({'queue_running': [[0, other, {}]], 'queue_pending': pending})
        self.reply({'error': 'not found'}, 404)
    def do_POST(self):
        self.record()
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
        if self.path == '/prompt':
            id = body['prompt_id']
            mode = body['prompt']['1']['inputs']['text']
            if mode == 'reject': return self.reply({'error': 'invalid fixture workflow'}, 400)
            with lock: jobs[id] = {'polls': 0, 'mode': mode, 'cancelled': False}
            return self.reply({'prompt_id': id})
        if self.path.startswith('/api/jobs/') and self.path.endswith('/cancel'):
            id = self.path.split('/')[3]
            with lock:
                job = jobs.get(id)
                changed = bool(job and not job['cancelled'] and (job['mode'] == 'cancel' or job['polls'] < 2))
                if changed: job['cancelled'] = True
            return self.reply({'cancelled': changed})
        self.reply({'error': 'unexpected action'}, 404)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(f'http://127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
