# Yo Human — installer (source, for inspection)

This repo holds the **Yo Human** installer scripts, published so you (and your AI assistant)
can **read exactly what they do before you run them.** Yo Human is a *trust product* — you
should never run an installer you can't inspect.

> 🔒 **Source-available, not open source.** Read it, run it for your own individual use —
> but no redistribution or derivative works. See [`LICENSE.md`](LICENSE.md).

## What's here
| File | What it sets up |
|---|---|
| [`install.sh`](install.sh) | **Claude Code** — global notification hooks so each session buzzes your phone (+ opt-in Approve/Reject) |
| [`cowork-install.sh`](cowork-install.sh) | **Claude Desktop / Cowork** — the Yo Human plug-in, registered in the Claude app |
| [`yohuman-mcp.mjs`](yohuman-mcp.mjs) | the Cowork plug-in itself (a small, dependency-free Node MCP server) |
| [`CHECKSUMS.txt`](CHECKSUMS.txt) | SHA-256 checksums (verify your download) |

## Inspect-first install (recommended)
```sh
# Cowork
curl -fsSL https://raw.githubusercontent.com/GITFischerAI/yohuman-install/main/cowork-install.sh -o yohuman-install.sh
less yohuman-install.sh                       # review it
shasum -a 256 yohuman-install.sh              # compare to CHECKSUMS.txt
YH_CHANNEL="your-channel" bash yohuman-install.sh
```
(For Claude Code, use `install.sh` and `YH_NOTIFY="your-channel"` instead.)

## What it does
- Notices when Claude finishes, needs your approval, or hits an error
- Sends a push to your paired phone (via the **ntfy** app) on your private channel
- Lets you Approve / Reject from your phone

## What it does NOT do
- ❌ Does not upload your source code
- ❌ Does not send `.env` secrets or file contents in notifications
- ❌ Does not deploy code, or run destructive commands on its own
- ❌ Does not modify unrelated projects or install machine-wide silently

## What changes on your Mac, and how to uninstall
Full details — every file/config touched, network calls, and exact uninstall steps:
**https://yohuman.ai/security**

---
Yo Human is a DBA of Brian Fischer (sole proprietor). An independent tool — not affiliated
with or endorsed by Anthropic.
