#!/bin/bash
# Yo Human — Cowork one-line installer.
# Meant to be run BY Claude Cowork on the user's Mac (it's agentic), e.g. the onboarding page
# tells the user to paste:  "Install Yo Human by running:
#   curl -fsSL https://yohuman.ai/cowork-install.sh | YH_CHANNEL='yohuman-cw-xxxx' bash"
# It places the Yo Human plug-in and registers it in the Claude Desktop app, wired to the
# user's channel. Delivery = Supabase push function → Apple Push → the Yo Human iOS app.
# No JSON editing, no jq — the merge is done with node. Existing Claude settings are preserved.
set -euo pipefail

CH="${YH_CHANNEL:-}"
# Reuse the existing channel if already set up; else generate one (so the user never has to invent a code).
if [ -z "$CH" ] && [ -f "$HOME/.yohuman-cowork/channel" ]; then CH="$(cat "$HOME/.yohuman-cowork/channel" 2>/dev/null)"; fi
if [ -z "$CH" ]; then
  set +o pipefail
  CODE="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
  set -o pipefail
  [ -n "$CODE" ] || CODE="$(date +%s)$$"
  CH="yohuman-cw-$CODE"
fi
mkdir -p "$HOME/.yohuman-cowork"; printf '%s' "$CH" > "$HOME/.yohuman-cowork/channel"
# Public Yo Human backend (publishable key only — browser-safe, RLS-protected).
PUSH_URL="${YH_PUSH_URL:-https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push}"
PUSH_KEY="${YH_PUSH_KEY:-sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1}"

YH_DIR="$HOME/.yohuman-cowork"
PLUGIN="$YH_DIR/yohuman-mcp.mjs"
CFG="${YH_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
PLUGIN_URL="${YH_PLUGIN_URL:-https://raw.githubusercontent.com/GITFischerAI/yohuman-install/main/yohuman-mcp.mjs}"

echo "== Yo Human — Cowork setup =="
mkdir -p "$YH_DIR"

# 1) Get the plug-in file (curl from the site; YH_PLUGIN_LOCAL overrides for testing)
if [ -n "${YH_PLUGIN_LOCAL:-}" ] && [ -f "$YH_PLUGIN_LOCAL" ]; then
  cp "$YH_PLUGIN_LOCAL" "$PLUGIN"
else
  curl -fsSL "$PLUGIN_URL" -o "$PLUGIN"
fi
[ -s "$PLUGIN" ] || { echo "❌ Couldn't fetch the plug-in."; exit 1; }
echo "✅ plug-in installed at $PLUGIN"

# 2) Find node (absolute path — GUI apps don't inherit your shell PATH)
NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "❌ Node.js not found. Install Node, then re-run."; exit 1; }

# 3) Merge into the Claude Desktop config (backup + merge with node, no jq, no clobber)
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] || echo '{}' > "$CFG"
cp "$CFG" "$CFG.yohuman-backup" 2>/dev/null || true
"$NODE" -e '
const fs = require("fs");
const [p, node, plugin, ch, url, key] = process.argv.slice(1);
let c = {};
try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
c.mcpServers = c.mcpServers || {};
c.mcpServers.yohuman = { command: node, args: [plugin], env: { YH_CHANNEL: ch, YH_PUSH_URL: url, YH_PUSH_KEY: key } };
fs.writeFileSync(p, JSON.stringify(c, null, 2));
' "$CFG" "$NODE" "$PLUGIN" "$CH" "$PUSH_URL" "$PUSH_KEY"
echo "✅ registered the Yo Human plug-in in Claude Desktop"

echo ""
echo "🎉 Almost done — two quick steps:"
echo "  1) QUIT and reopen the Claude app (so it loads the plug-in)."
echo "  2) Open the Yo Human app on your phone and pair with this code:  $CH"
echo ""
echo "Then ask Cowork to do anything — your phone will buzz."
