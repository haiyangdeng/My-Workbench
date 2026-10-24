# On-demand GPU servers

How to connect a ComfyUI server that runs on a rented cloud GPU and is only switched on while you need it. This covers PRD MD-01, MD-02, MD-04 and MD-16 to MD-18.

## Add the server

Go to **工具连接 → 添加服务器**.

| Field | What to enter |
| --- | --- |
| 主机 | A `Host` alias from `~/.ssh/config`, or the address the provider gives, such as `connect.example.com` or an IP address |
| 用户名, SSH 端口 | Optional. They override `~/.ssh/config`. Rented instances often use `root` and a high port |
| 登录方式 | **私钥或 ssh-agent** (recommended): optionally pick a key file, otherwise ssh-agent and `~/.ssh/config` are used. **密码**: the password is stored in the Keychain only (see below) |
| 主机密钥 | **首次连接时信任新主机**: right for instances that are new each time. A host whose key *changed* is still refused. **只接受 known_hosts 中已有的主机**: strict |
| 本机端口, ComfyUI 端口 | ComfyUI on the server (usually 8188) is reached at `127.0.0.1:<本机端口>` on this Mac. Nothing is opened to the network |
| ComfyUI 地址（从 SSH 主机看） | Leave as `127.0.0.1`, unless ComfyUI runs on another machine behind the SSH host |
| 启动命令, 停止命令 | Optional, one argument per line, for example your provider's CLI. They run only when you click **启动** or **停止** |
| 启动后等待就绪 | How long **启动** waits for SSH and ComfyUI to answer (default 300 s) |
| 需要 Bearer API 凭证 | For ComfyUI behind an HTTPS gateway with a token. The token is kept in the Keychain |
| 价格, 同时运行, 上传/下载上限, 超时 | Used for estimates, budgets and limits |

**Passwords.**

- The password is kept in the Keychain under the server's ID.
- When connecting, `ssh` asks the `SSH_ASKPASS` helper, which reads the password from the environment of that one `ssh` process. The password never appears in argv, the workspace database or logs.
- Deleting the server removes the password from the Keychain.
- Use a key when the provider allows one.

## Use it

On the server card:

- **测试连接** checks each stage in turn: SSH login, tunnel, ComfyUI, single-job cancel, and installed nodes. Each stage reports its own result.
- **启动** runs your start command, then waits until SSH and ComfyUI answer, opening the tunnel.
- **停止** runs your stop command and closes the tunnel. It asks first if jobs are still running.
- **连接 / 断开 SSH 隧道** opens or closes the tunnel by hand.

When a job runs:

- **Opening.** The tunnel opens on its own before any job is submitted.
- **Server off.** If the server is off, nothing is submitted. The step fails with "start the server, then retry", and the plan pauses.
- **Drops.** If the tunnel drops while a job runs, polling keeps trying for about a minute and reopens the tunnel, at most three times. A job is never submitted twice; a job that can't be confirmed is left as Interrupted.
- **Health.** GPU, VRAM and queue refresh every 30 seconds while jobs run.

## Directing with Codex (or another CLI)

1. In a Video, Audio or Design project, pick one agent and switch on **导演** in the composer.
2. The scope menu next to it sets which templates and servers the director may plan with. By default these are the templates of the project's modules and the servers whose last check did not fail. The scope is saved with the message.
3. Approve the plan with a budget. Zero or a negative number is refused. A plan with generate steps needs at least one cap.
4. Every variant is checked against the budget before it is submitted.

## Messages and what to do

| Message | Meaning |
| --- | --- |
| SSH 认证失败 | Wrong user, key or password, or the server doesn't accept that login method |
| 主机密钥变了 | The instance was rebuilt or the IP was reused. Run `ssh-keygen -R <host>` once you are sure |
| 还不在 known_hosts 中 | Choose “首次连接时信任新主机”, or connect once with `ssh` in Terminal |
| SSH 端口拒绝连接 / 连接超时 | The instance is not running yet, or the port is wrong. Click **启动** |
| 本机端口已被占用 | Pick another 本机端口 |
| 转发到 ComfyUI 端口失败 / ComfyUI 没有响应 | SSH works, but ComfyUI isn't running or the port is wrong |
| 不支持按编号取消单个任务 | Update ComfyUI. Jobs can't run without `/api/jobs` |

## Checks

| Command | What it covers |
| --- | --- |
| `zsh scripts/verify_servers.sh` | A stand-in `ssh` (`scripts/fixtures/ssh_like.py`) and the local ComfyUI fixture: key and password login, failures, start/stop, offline server, auto-connect, a drop mid-job, health refresh, and Keychain cleanup |
| `zsh scripts/verify_servers.sh --real-codex` | Adds a real Codex-directed image through the SSH server |

A live cloud server, its provider CLI and real network drops still need one run with your server.
