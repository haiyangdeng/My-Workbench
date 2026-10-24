# Example CLI definitions

These are the PRD Appendix A values as Workbench definition files. The app ships none of them. To use one, open
**工具连接 → 导入 CLI 定义…**, pick the file, then click **修正路径** and pick the executable, or type `claude` or `codex`
and press **查找**. Check the login, then send a test prompt.

| File | CLI | Checked against |
| --- | --- | --- |
| `claude-code.json` | Claude Code | `claude --help`, version 2.1.287 |
| `codex.json` | Codex | `codex exec --help` and `codex exec resume --help`, version 0.164.0 |

`Tests/WorkbenchCoreTests/CLIExampleTests.swift` checks the exact argv each file produces for a new turn, a resumed
turn, Read-only and Edit access, a model, structured output and the terminal hand-off. `python3 -I scripts/verify_cli_flags.py`
checks every flag against the installed CLI's own help, without calling a model.

Neither file carries credentials. To use Claude Code through an API relay instead of `claude auth login`, add the
variables in the definition's **网络与环境变量** section, for example `ANTHROPIC_BASE_URL` as a plain variable and
`ANTHROPIC_AUTH_TOKEN` as a secret one (stored in the Keychain, never exported).
