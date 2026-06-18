#!/bin/bash
# install-yohuman.sh — set up Yo Human on ANY Mac, for EVERY Claude Code project.
#
# Installs global Claude Code hooks so every terminal Claude Code session on this
# machine notifies your iPhone (via the ntfy app), plus the opt-in two-way
# phone-approval scripts. Copy this one file to another Mac and run it.
#
# Usage:
#   YH_NOTIFY="your-ntfy-channel" bash install-yohuman.sh
#   (or just run it and it will ask for your notify channel)
#
# Requires: jq, curl (curl is built in; install jq with `brew install jq`).
set -euo pipefail

YH="$HOME/.yohuman"
SETTINGS="$HOME/.claude/settings.json"
NTFY="https://ntfy.sh"

say(){ printf '%s\n' "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { say "❌ '$1' is required but missing."; exit 1; }; }
# Make sure jq is available WITHOUT the user needing to know what brew/jq are.
ensure_jq(){
  command -v jq >/dev/null 2>&1 && return 0
  say "Setting up a small helper — one moment…"
  command -v brew >/dev/null 2>&1 && brew install jq >/dev/null 2>&1 || true
  command -v jq >/dev/null 2>&1 && return 0
  mkdir -p "$YH/bin"
  case "$(uname -m)" in
    arm64) JQURL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64";;
    *)     JQURL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64";;
  esac
  curl -fsSL "$JQURL" -o "$YH/bin/jq" 2>/dev/null && chmod +x "$YH/bin/jq" && export PATH="$YH/bin:$PATH"
  command -v jq >/dev/null 2>&1
}

say "== Yo Human installer =="
need curl
mkdir -p "$YH/approvals" "$HOME/.claude" "$YH/bin"
ensure_jq || { say "❌ Couldn't set up the jq helper automatically. As a last resort, install Homebrew from brew.sh, then run: brew install jq — and run this again."; exit 1; }

# --- 1. Notify channel (your iPhone is subscribed to this in the ntfy app) ---
NOTIFY="${YH_NOTIFY:-}"
if [ -z "$NOTIFY" ]; then
  printf "Your ntfy notify channel (the topic your iPhone is subscribed to): "
  read -r NOTIFY
fi
[ -n "$NOTIFY" ] || { say "❌ A notify channel is required."; exit 1; }

# --- 2. Secret command channel (for two-way approval; auto-generated) ---
if [ -f "$YH/config.sh" ] && grep -q COMMAND_CHANNEL "$YH/config.sh"; then
  # shellcheck disable=SC1090
  . "$YH/config.sh"; CMD="${COMMAND_CHANNEL:-}"
fi
[ -n "${CMD:-}" ] || CMD="yohuman-cmd-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 16)"

cat > "$YH/config.sh" <<CONFIG_EOF
# Yo Human config (this machine)
NTFY_SERVER="$NTFY"
NOTIFY_CHANNEL="$NOTIFY"
COMMAND_CHANNEL="$CMD"
APPROVALS_DIR="\$HOME/.yohuman/approvals"
APPROVAL_TIMEOUT=55

# Anonymous usage telemetry → Supabase (records the event TYPE only; no code, no content).
SB_EVENTS_URL="https://ahfdcubxjcahonmzdoww.supabase.co/rest/v1/events"
SB_KEY="sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1"
TELEMETRY_ID="$NOTIFY"
CONFIG_EOF
chmod 600 "$YH/config.sh"
say "✅ config written ($YH/config.sh)"

# --- 2b. Usage event logger (one tiny event TYPE per action; links to this tester) ---
cat > "$YH/yohuman-event.sh" <<'EVENT_EOF'
#!/bin/bash
# yohuman-event.sh <type> — log ONE usage event TYPE to Supabase. No code/content. Non-blocking.
. "$HOME/.yohuman/config.sh" 2>/dev/null
[ -n "${SB_EVENTS_URL:-}" ] || exit 0
curl -s -X POST "$SB_EVENTS_URL" \
  -H "apikey: ${SB_KEY}" \
  -H "Authorization: Bearer ${SB_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{\"user_id\":\"${TELEMETRY_ID:-anon}\",\"type\":\"$1\"}" >/dev/null 2>&1
exit 0
EVENT_EOF
chmod +x "$YH/yohuman-event.sh"

# --- 3. Approval hook script (default: notify-only; opt-in two-way approval) ---
cat > "$YH/yohuman-approval-hook.sh" <<'HOOK_EOF'
#!/bin/bash
# Yo Human PermissionRequest hook. Notify-only unless ~/.yohuman/approve-enabled
# exists AND the listener is running (then: Allow once / Allow always / Reject).
set -uo pipefail
. "$HOME/.yohuman/config.sh" 2>/dev/null
export PATH="$HOME/.yohuman/bin:$PATH"
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // "a tool"' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
proj=$(basename "$cwd" 2>/dev/null)
NOTIFY_URL="${NTFY_SERVER:-https://ntfy.sh}/${NOTIFY_CHANNEL:-}"
case "$tool" in *[Pp]review*|*[Cc]hrome*) exit 0;; esac
[ -f "$HOME/.yohuman/mute" ] && exit 0   # Do Not Disturb
bash "$HOME/.yohuman/yohuman-event.sh" approval &   # usage telemetry (non-blocking)
if [ ! -f "$HOME/.yohuman/approve-enabled" ]; then
  curl -s -H "Title: Claude Code — $proj" -H "Priority: high" -H "Tags: warning" \
    -d "🔔 Needs your approval to use $tool in $proj" "$NOTIFY_URL" >/dev/null 2>&1 || true
  exit 0
fi
[ -n "${COMMAND_CHANNEL:-}" ] || exit 0
start=$(date +%s)
arg=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.file_path // empty' 2>/dev/null | head -1 | cut -c1-90)
label="$tool"; [ -n "$arg" ] && label="$tool — $arg"
CMD_URL="${NTFY_SERVER:-https://ntfy.sh}/${COMMAND_CHANNEL}"
ACTIONS="http, Allow once, ${CMD_URL}, method=POST, body=allowonce, clear=true; http, Allow always, ${CMD_URL}, method=POST, body=allowalways, clear=true; http, Reject, ${CMD_URL}, method=POST, body=reject, clear=true"
curl -s -H "Title: Approve in ${proj}?" -H "Priority: max" -H "Tags: lock" -H "Actions: ${ACTIONS}" \
  -d "🔐 Claude wants to use ${label}" "$NOTIFY_URL" >/dev/null 2>&1 || true
LD="$HOME/.yohuman/last-decision"; deadline=$(( start + ${APPROVAL_TIMEOUT:-55} )); decision=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$LD" ]; then d=$(awk '{print $1}' "$LD" 2>/dev/null); t=$(awk '{print $2}' "$LD" 2>/dev/null); if [ -n "$d" ] && [ -n "$t" ] && [ "$t" -ge "$start" ] 2>/dev/null; then decision="$d"; rm -f "$LD"; break; fi; fi
  sleep 1
done
[ -z "$decision" ] && exit 0
add_rule(){ local r="$1" f="$HOME/.claude/settings.json" t; t="$(mktemp)"||return 0; if jq --arg r "$r" '.permissions.allow=((.permissions.allow//[])+[$r]|unique)' "$f">"$t" 2>/dev/null; then mv "$t" "$f"; else rm -f "$t"; fi; }
confirm(){ curl -s -H "Title: Yo Human · $proj" -H "Priority: low" -H "Tags: white_check_mark" -d "$1" "$NOTIFY_URL" >/dev/null 2>&1 || true; }
tele(){ bash "$HOME/.yohuman/yohuman-event.sh" "$1" & }
ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
DENY='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","reason":"Rejected from phone"}}}'
case "$decision" in
  allowonce) tele allow_once; confirm "✅ Got it — allowing once: $label. Proceeding."; printf '%s' "$ALLOW";;
  allowalways) tele allow_always; if [ "$tool" = "Bash" ]; then confirm "✅ Got it — allowing once (Bash stays ask-each-time): $label. Proceeding."; printf '%s' "$ALLOW"; else { [ -n "$arg" ] && add_rule "${tool}(${arg})" || add_rule "$tool"; }; confirm "✅ Got it — allowing always: $label. Won'\''t ask again."; printf '%s' "$ALLOW"; fi;;
  reject) tele reject; confirm "🚫 Got it — rejected: $label. Stopping."; printf '%s' "$DENY";;
  *) exit 0;;
esac
exit 0
HOOK_EOF
chmod +x "$YH/yohuman-approval-hook.sh"

# --- 4. Listener script (only needed when two-way approval is enabled) ---
cat > "$YH/yohuman-approval-listener.sh" <<'LISTENER_EOF'
#!/bin/bash
# Yo Human approval listener — records phone taps from the command channel.
set -uo pipefail
. "$HOME/.yohuman/config.sh" 2>/dev/null || { echo "no config"; exit 1; }
export PATH="$HOME/.yohuman/bin:$PATH"
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
: "${COMMAND_CHANNEL:?command channel not set}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"; AD="${APPROVALS_DIR:-$HOME/.yohuman/approvals}"
SF="$HOME/.yohuman/listener.since"; mkdir -p "$AD"; [ -f "$SF" ] || date +%s > "$SF"
echo "listening → ${NTFY_SERVER}/${COMMAND_CHANNEL}"; B=2
while true; do
  S="$(cat "$SF" 2>/dev/null || echo now)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | jq -r '.event // empty' 2>/dev/null)" = "message" ] || continue
    msg=$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null); mt=$(printf '%s' "$line" | jq -r '.time // empty' 2>/dev/null)
    [ -n "$msg" ] || continue
    d="$msg"
    case "$d" in allowonce|allowalways|reject) ;; *) continue;; esac
    t="${mt:-$(date +%s)}"; case "$t" in ''|*[!0-9]*) t="$(date +%s)";; esac
    printf '%s %s' "$d" "$t" > "$HOME/.yohuman/last-decision.tmp" && mv "$HOME/.yohuman/last-decision.tmp" "$HOME/.yohuman/last-decision"; echo "$t" > "$SF"; echo "recorded: $d @ $t"; B=2
  done < <(curl -sN "${NTFY_SERVER}/${COMMAND_CHANNEL}/json?since=${S}" 2>/dev/null)
  sleep "$B"; B=$(( B<30 ? B*2 : 30 ))
done
LISTENER_EOF
chmod +x "$YH/yohuman-approval-listener.sh"

# --- 4b. Toggle scripts (auto-start listener via launchd while two-way is ON) ---
cat > "$YH/yohuman-approve-on.sh" <<'ONSH_EOF'
#!/bin/bash
set -euo pipefail
YH="$HOME/.yohuman"; LA="$HOME/Library/LaunchAgents"; PLIST="$LA/com.yohuman.listener.plist"
mkdir -p "$LA"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.yohuman.listener</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$YH/yohuman-approval-listener.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$YH/listener.log</string>
  <key>StandardErrorPath</key><string>$YH/listener.log</string>
</dict>
</plist>
PLIST_EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
touch "$YH/approve-enabled"; sleep 1
pgrep -f yohuman-approval-listener.sh >/dev/null 2>&1 \
  && echo "🟢 Two-way phone approval is ON (listener auto-starts at login + restarts on crash)." \
  || echo "🟡 Enabled, but the listener didn't start. Check $YH/listener.log"
ONSH_EOF
chmod +x "$YH/yohuman-approve-on.sh"

cat > "$YH/yohuman-approve-off.sh" <<'OFFSH_EOF'
#!/bin/bash
set -euo pipefail
YH="$HOME/.yohuman"; PLIST="$HOME/Library/LaunchAgents/com.yohuman.listener.plist"
rm -f "$YH/approve-enabled"
[ -f "$PLIST" ] && launchctl unload -w "$PLIST" 2>/dev/null || true
pkill -f yohuman-approval-listener.sh 2>/dev/null || true
rm -f "$YH/last-decision" 2>/dev/null || true
echo "⚪ Two-way phone approval is OFF. Back to notify-only; listener stopped."
OFFSH_EOF
chmod +x "$YH/yohuman-approve-off.sh"

say "✅ scripts installed in $YH/"

# --- 5. Merge the global hooks into ~/.claude/settings.json (no clobber) ---
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
MUTE="[ -f \"\$HOME/.yohuman/mute\" ] && exit 0; "
N_CMD="${MUTE}dir=\$(jq -r '.cwd // \"\"'); proj=\$(basename \"\$dir\"); curl -s -H \"Title: Claude Code — \$proj\" -H \"Priority: high\" -H \"Tags: speech_balloon\" -d \"💬 Waiting for your answer in \$proj\" $NTFY/$NOTIFY >/dev/null 2>&1 || true"
S_CMD="${MUTE}dir=\$(jq -r '.cwd // \"\"'); proj=\$(basename \"\$dir\"); curl -s -H \"Title: Claude Code — \$proj\" -H \"Priority: default\" -H \"Tags: white_check_mark\" -d \"✅ Claude Code finished in \$proj\" $NTFY/$NOTIFY >/dev/null 2>&1 || true; bash \"\$HOME/.yohuman/yohuman-event.sh\" completion &"
F_CMD="${MUTE}dir=\$(jq -r '.cwd // \"\"'); proj=\$(basename \"\$dir\"); curl -s -H \"Title: Claude Code — \$proj\" -H \"Priority: high\" -H \"Tags: rotating_light\" -d \"⚠️ Error in \$proj\" $NTFY/$NOTIFY >/dev/null 2>&1 || true; bash \"\$HOME/.yohuman/yohuman-event.sh\" error &"

tmp="$(mktemp)"
jq \
  --arg pr 'bash "$HOME/.yohuman/yohuman-approval-hook.sh"' \
  --arg n "$N_CMD" --arg s "$S_CMD" --arg f "$F_CMD" '
  .hooks.PermissionRequest = [ { hooks: [ { type:"command", command:$pr, timeout:70 } ] } ]
  | .hooks.Notification    = [ { matcher:"idle_prompt", hooks: [ { type:"command", command:$n } ] } ]
  | .hooks.Stop            = [ { hooks: [ { type:"command", command:$s } ] } ]
  | .hooks.StopFailure     = [ { hooks: [ { type:"command", command:$f } ] } ]
  | .permissions.allow = ((.permissions.allow // []) + ["Bash(bash ~/.yohuman/yohuman-on.sh)","Bash(bash ~/.yohuman/yohuman-off.sh)"] | unique)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; say "❌ failed to update $SETTINGS"; exit 1; }
say "✅ global hooks installed in $SETTINGS"

# --- 5b. On/off toggle scripts + natural-language control ("Yo Human, I'm away") ---
cat > "$YH/yohuman-on.sh" <<'ON2_EOF'
#!/bin/bash
rm -f "$HOME/.yohuman/mute"
. "$HOME/.yohuman/config.sh" 2>/dev/null
curl -s -H "Title: Yo Human" -H "Tags: bell" -d "🔔 You're on — I'll buzz you the moment Claude needs you." "${NTFY_SERVER:-https://ntfy.sh}/${NOTIFY_CHANNEL}" >/dev/null 2>&1 || true
echo "🔔 Yo Human is ON — your phone will buzz when Claude needs you."
ON2_EOF
cat > "$YH/yohuman-off.sh" <<'OFF2_EOF'
#!/bin/bash
touch "$HOME/.yohuman/mute"
echo "🔕 Yo Human is OFF — muted while you work."
OFF2_EOF
chmod +x "$YH/yohuman-on.sh" "$YH/yohuman-off.sh"

CM="$HOME/.claude/CLAUDE.md"
if ! grep -q "Yo Human — phone notification control" "$CM" 2>/dev/null; then
  cat >> "$CM" <<'CM_EOF'

## Yo Human — phone notification control

Yo Human buzzes my phone when Claude Code needs me. I toggle it by talking to it in plain English (usually starting with "Yo Human"). Read my intent and run the matching command immediately without asking (both are safe + pre-approved):

- Stepping away / want to be notified ("I'm away", "going for a walk", "heading out", "notify me", "wake up", "ping me", "turn on") → run: `bash ~/.yohuman/yohuman-on.sh`
- Back at the desk / want quiet ("I'm back", "mute", "quiet", "shhh", "shut up", "off", "sleep") → run: `bash ~/.yohuman/yohuman-off.sh`
CM_EOF
  say "✅ natural-language control added to $CM"
fi

# --- 6. Record the install (one event), then done ---
bash "$YH/yohuman-event.sh" install >/dev/null 2>&1 || true
say ""
say "🎉 Done. RESTART Claude Code, then every project on this Mac will notify your iPhone."
say "   Notify channel: $NOTIFY   (make sure the ntfy app on your phone is subscribed to it)"
say ""
say "Optional — two-way phone approval (Allow once / always / Reject):"
say "   turn ON:   bash ~/.yohuman/yohuman-approve-on.sh    (listener auto-starts at login)"
say "   turn OFF:  bash ~/.yohuman/yohuman-approve-off.sh"
say ""
say "Control it by just TALKING to Claude Code (any project):"
say "   \"Yo Human, I'm going for a walk\"  →  turns notifications ON"
say "   \"Yo Human, I'm back\" / \"quiet\"     →  mutes (do not disturb)"
say "(manual: touch ~/.yohuman/mute to mute, rm ~/.yohuman/mute to unmute)"
