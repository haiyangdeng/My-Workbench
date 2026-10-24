#!/usr/bin/python3 -I
"""Test stand-in for /usr/bin/ssh, used by scripts/verify_servers.swift. It never opens a network connection beyond
127.0.0.1. A tunnel (-N -L 127.0.0.1:LOCAL:HOST:PORT) listens on LOCAL and forwards to the ComfyUI fixture whose port
is in state/target. Behaviour comes from files in state/ next to this script:
  mode      ok (default), auth-fail, hostkey-changed, down, or booting:<epoch> (down until that time, like an
            instance a provider API has just started)
  password  if present, the password ssh must get from SSH_ASKPASS (with SSH_ASKPASS_REQUIRE=force)
  drop      if present, a tunnel exits after this many seconds (the file is removed, so the next tunnel stays up)
Every call is appended to state/calls.jsonl."""
import json, os, socket, sys, threading, time

here = os.path.dirname(os.path.abspath(__file__))
state = os.path.join(here, "state")
os.makedirs(state, exist_ok=True)
args = sys.argv[1:]


def read(name, default=""):
    try:
        return open(os.path.join(state, name)).read().strip()
    except OSError:
        return default


def record(**fields):
    with open(os.path.join(state, "calls.jsonl"), "a") as f:
        f.write(json.dumps(dict(argv=args, time=time.time(), **fields)) + "\n")


def fail(message):
    record(result="fail", message=message)
    sys.stderr.write(message + "\n"); sys.stderr.flush()
    sys.exit(255)


# Parse the options Workbench passes.
forward = None; options = {}; positional = []
i = 0
while i < len(args):
    a = args[i]
    if a in ("-L", "-o", "-p", "-i", "-l"):
        value = args[i + 1]; i += 2
        if a == "-L": forward = value
        elif a == "-o": key, _, v = value.partition("="); options[key] = v
        else: options[a] = value
        continue
    if a in ("-N", "-T"): i += 1; continue
    positional.append(a); i += 1
host = positional[0] if positional else ""
mode = read("mode", "ok")
if mode.startswith("booting:"):
    mode = "ok" if time.time() >= float(mode.split(":", 1)[1]) else "down"
if mode == "down":
    fail(f"ssh: connect to host {host} port {options.get('-p', '22')}: Connection refused")
if mode == "hostkey-changed":
    fail("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.")
if mode == "auth-fail":
    fail(f"{options.get('-l', 'user')}@{host}: Permission denied (publickey,password).")
expected = read("password", None) if os.path.exists(os.path.join(state, "password")) else None
password_ok = None
if expected is not None:
    askpass = os.environ.get("SSH_ASKPASS")
    if not askpass or os.environ.get("SSH_ASKPASS_REQUIRE") != "force" or options.get("BatchMode") != "no":
        fail(f"{host}: Permission denied (password).")
    import subprocess
    given = subprocess.run([askpass, "root@" + host + "'s password: "], capture_output=True, text=True).stdout.rstrip("\n")
    password_ok = given == expected
    if not password_ok:
        fail(f"{host}: Permission denied (password).")

if forward is None:
    # Login probe: `ssh ... host true`.
    record(result="probe", host=host, password_ok=password_ok)
    sys.exit(0 if positional[1:] == ["true"] else 1)

bind, local, remote_host, remote_port = forward.split(":")
target = int(read("target"))
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)  # as OpenSSH does for forwarded ports
try:
    listener.bind((bind, int(local)))
except OSError:
    fail(f"bind [{bind}]:{local}: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: {local}\nCould not request local forwarding.")
listener.listen(16)
record(result="tunnel", host=host, local=int(local), remote=f"{remote_host}:{remote_port}", password_ok=password_ok)


def pump(source, sink):
    try:
        while True:
            data = source.recv(65536)
            if not data: break
            sink.sendall(data)
    except OSError:
        pass
    finally:
        for s in (source, sink):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass


def serve():
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        upstream = socket.create_connection(("127.0.0.1", target))
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


threading.Thread(target=serve, daemon=True).start()
drop = read("drop")
if drop:
    os.remove(os.path.join(state, "drop"))
    time.sleep(float(drop))
    record(result="dropped", host=host)
    sys.stderr.write("client_loop: send disconnect: Broken pipe\n"); sys.exit(255)
while True:
    time.sleep(3600)
