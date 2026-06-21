#!/bin/bash
# install-yohuman.sh — set up Yo Human on ANY Mac, for EVERY Claude Code project.
#
# Installs global Claude Code hooks so every terminal Claude Code session on this
# machine buzzes your iPhone through the **Yo Human app** (Supabase push → Apple Push),
# plus the opt-in two-way phone-approval (Allow / Reject right from your phone).
# Copy this one file to another Mac and run it.
#
# Delivery path: Claude hook → Supabase `push` function → APNs → Yo Human iOS app.
# (No ntfy. The channel code this prints is what you paste into the app to pair.)
#
# Usage:
#   bash install-yohuman.sh                 # generates a channel code for you
#   YH_CHANNEL="my-existing-code" bash install-yohuman.sh   # reuse a code
#
# Requires: jq, curl (curl is built in; this will set up jq for you).
set -euo pipefail

YH="$HOME/.yohuman"
SETTINGS="$HOME/.claude/settings.json"

# Public Yo Human backend (publishable key only — browser-safe, RLS-protected).
PUSH_URL="https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push"
EVENTS_URL="https://ahfdcubxjcahonmzdoww.supabase.co/rest/v1/events"
PUB_KEY="sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1"

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
mkdir -p "$HOME/.claude" "$YH/bin"
ensure_jq || { say "❌ Couldn't set up the jq helper automatically. As a last resort, install Homebrew from brew.sh, then run: brew install jq — and run this again."; exit 1; }

# --- 1. Channel code (this is what you paste into the Yo Human app to pair) ---
# Reuse the existing channel if this machine was set up before; else use $YH_CHANNEL; else generate one.
CHANNEL="${YH_CHANNEL:-}"
if [ -z "$CHANNEL" ] && [ -f "$YH/config.sh" ]; then
  # shellcheck disable=SC1090
  . "$YH/config.sh" 2>/dev/null || true; CHANNEL="${YH_PUSH_CHANNEL:-}"
fi
# Reuse the Cowork channel if that was set up first — one phone code covers BOTH surfaces.
if [ -z "$CHANNEL" ] && [ -f "$HOME/.yohuman-cowork/channel" ]; then CHANNEL="$(cat "$HOME/.yohuman-cowork/channel" 2>/dev/null)"; fi
if [ -z "$CHANNEL" ]; then
  set +o pipefail
  CODE="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
  set -o pipefail
  [ -n "$CODE" ] || CODE="$(date +%s)$$"
  CHANNEL="yohuman-$CODE"
fi

# --- 2. Config (delivery via the native app — Supabase push → APNs) ---
cat > "$YH/config.sh" <<CONFIG_EOF
# Yo Human config (this machine). Delivery = Supabase push function → Apple Push → the app.
APPROVAL_TIMEOUT=60   # seconds Claude waits for your phone tap before falling back to the keyboard

# Anonymous usage telemetry → Supabase (records the event TYPE only; no code, no content).
SB_EVENTS_URL="$EVENTS_URL"
SB_KEY="$PUB_KEY"
TELEMETRY_ID="$CHANNEL"

# Native app push. Channel = the code you paste into the Yo Human app.
YH_PUSH_URL="$PUSH_URL"
YH_PUSH_CHANNEL="$CHANNEL"
YH_PUSH_KEY="$PUB_KEY"

# Friendly project names on your alert cards (folder name → what you see). Add lines as you like.
yh_projname() {
  case "\$1" in
    *) echo "\$1" ;;
  esac
}
CONFIG_EOF
chmod 600 "$YH/config.sh"
say "✅ config written ($YH/config.sh)"

# --- 2b. Usage event logger (one tiny event TYPE per action; powers your stats screen) ---
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

# --- 3. Notify script (waiting / finished / error → app push, no buttons) ---
cat > "$YH/yohuman-push.sh" <<'PUSH_EOF'
#!/usr/bin/env bash
# yohuman-push.sh <event> — buzz the Yo Human iOS app via the Supabase push fn.
# Reads the hook JSON from stdin (for the project name). Respects the mute file.
[ -f "$HOME/.yohuman/mute" ] && exit 0
. "$HOME/.yohuman/config.sh" 2>/dev/null
EVENT="${1:-notify}"
INPUT="$(cat 2>/dev/null)"
DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
PROJ="$(basename "$DIR" 2>/dev/null)"; [ -z "$PROJ" ] && PROJ="your project"
command -v yh_projname >/dev/null 2>&1 && PROJ="$(yh_projname "$PROJ")"
case "$EVENT" in
  idle)  TITLE="Waiting in $PROJ";  BODY="Claude is waiting for your answer";   TELE="";;
  stop)  TITLE="Finished in $PROJ"; BODY="Claude Code finished — ready for you"; TELE="completion";;
  error) TITLE="Error in $PROJ";    BODY="Claude hit an error — needs you";      TELE="error";;
  *)     TITLE="Yo Human";          BODY="Claude needs you";                     TELE="";;
esac
[ -n "$TELE" ] && bash "$HOME/.yohuman/yohuman-event.sh" "$TELE" &
URL="${YH_PUSH_URL:-https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push}"
CH="${YH_PUSH_CHANNEL:-}"
KEY="${YH_PUSH_KEY:-}"
# category "INFO" = no Allow/Reject buttons (those belong only on real two-way approvals).
PAYLOAD="$(jq -n --arg c "$CH" --arg t "$TITLE" --arg b "$BODY" '{channel:$c,title:$t,body:$b,category:"INFO"}')"
curl -s -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" \
  -H "Content-Type: application/json" -d "$PAYLOAD" >/dev/null 2>&1 || true
exit 0
PUSH_EOF
chmod +x "$YH/yohuman-push.sh"

# --- 4. Approval hook (default: notify-only; opt-in two-way via Supabase, NO listener) ---
cat > "$YH/yohuman-approval-hook.sh" <<'HOOK_EOF'
#!/bin/bash
# yohuman-approval-hook.sh — Claude Code PermissionRequest hook (Yo Human app, Supabase two-way).
# DEFAULT (no ~/.yohuman/approve-enabled): notify-only push, normal keyboard approval.
# ENABLED (approve-enabled present): push with Allow/Reject, WAIT for the phone tap via
#   Supabase get_decision, return the decision so Claude proceeds. No tap in time → keyboard fallback.
set -uo pipefail
CONFIG="$HOME/.yohuman/config.sh"; [ -f "$CONFIG" ] && . "$CONFIG"
export PATH="$HOME/.yohuman/bin:$PATH"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // "a tool"' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
proj=$(basename "$cwd" 2>/dev/null); [ -z "$proj" ] && proj="your project"
command -v yh_projname >/dev/null 2>&1 && proj="$(yh_projname "$proj")"
case "$tool" in *[Pp]review*|*[Cc]hrome*) exit 0;; esac
[ -f "$HOME/.yohuman/mute" ] && exit 0
bash "$HOME/.yohuman/yohuman-event.sh" approval &

arg=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.file_path // empty' 2>/dev/null | head -1 | cut -c1-120)
desc=$(printf '%s' "$input" | jq -r '.tool_input.description // .permission_suggestions[0] // empty' 2>/dev/null | head -1 | cut -c1-120)
# Prefer Claude's own human description (keeps raw commands — and any secrets — off your lock screen).
if [ -n "$desc" ]; then label="$desc"
elif [ -n "$arg" ]; then label="$tool — $arg"
else label="$tool"; fi

URL="${YH_PUSH_URL:-https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push}"
RPC="${URL%/functions/v1/push}/rest/v1/rpc"
CH="${YH_PUSH_CHANNEL:-}"
KEY="${YH_PUSH_KEY:-}"

# ---- QUESTIONS: Claude is asking YOU (often multiple-choice) — NOT an allow/reject. ----
# Notify only (no buttons), then let the question appear on your Mac to answer.
case "$tool" in
  *AskUserQuestion*|*[Qq]uestion*)
    q=$(printf '%s' "$input" | jq -r '.tool_input.questions[0].question // .tool_input.question // empty' 2>/dev/null | head -1 | cut -c1-160)
    [ -n "$q" ] || q="Claude Code has a question that needs your answer."
    jq -n --arg c "$CH" --arg t "Question in $proj" --arg b "$q" \
      '{channel:$c,title:$t,body:$b,category:"INFO"}' \
      | curl -s -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true
    exit 0
    ;;
esac

# ---- DEFAULT: notify-only ----
if [ ! -f "$HOME/.yohuman/approve-enabled" ]; then
  jq -n --arg c "$CH" --arg t "Approve in $proj?" --arg b "$label" \
    '{channel:$c,title:$t,body:$b,category:"INFO"}' \
    | curl -s -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true
  exit 0
fi

# ---- ENABLED: two-way ----
REQ="yh-$(date +%s)-$$-${RANDOM}${RANDOM}"
start=$(date +%s)
echo "$(date '+%H:%M:%S') [$proj] two-way START REQ=$REQ tool=$tool" >> "$HOME/.yohuman/approval.log"
jq -n --arg c "$CH" --arg t "Approve in $proj?" --arg b "$label" --arg r "$REQ" \
  '{channel:$c,title:$t,body:$b,category:"APPROVAL",request_id:$r}' \
  | curl -s -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true

deadline=$(( start + ${APPROVAL_TIMEOUT:-180} ))
decision=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  resp=$(curl -s -X POST "$RPC/get_decision" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" -d "{\"p_request_id\":\"$REQ\"}" 2>/dev/null)
  d=$(printf '%s' "$resp" | tr -d '"[:space:]')
  case "$d" in allowonce|allowalways|reject) decision="$d"; break;; esac
  sleep 1.5
done
echo "$(date '+%H:%M:%S') [$proj] two-way END REQ=$REQ decision='${decision:-TIMEOUT}'" >> "$HOME/.yohuman/approval.log"
[ -z "$decision" ] && exit 0

add_rule() { local rule="$1" f="$HOME/.claude/settings.json" tmp; tmp="$(mktemp)" || return 0
  if jq --arg r "$rule" '.permissions.allow = ((.permissions.allow // []) + [$r] | unique)' "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; fi; }
tele() { bash "$HOME/.yohuman/yohuman-event.sh" "$1" & }

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
DENY='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","reason":"Rejected from phone"}}}'

# No separate confirmation push — the app's in-thread "Thanks, human" already confirms it.
case "$decision" in
  allowonce)  tele allow_once; printf '%s' "$ALLOW";;
  allowalways)
    if [ "$tool" = "Bash" ]; then tele allow_once; printf '%s' "$ALLOW"
    else { [ -n "$arg" ] && add_rule "${tool}(${arg})" || add_rule "$tool"; }; tele allow_always; printf '%s' "$ALLOW"; fi;;
  reject) tele reject; printf '%s' "$DENY";;
esac
exit 0
HOOK_EOF
chmod +x "$YH/yohuman-approval-hook.sh"

# --- 4b. Two-way toggle (just a flag — NO listener/launchd anymore; the hook polls Supabase) ---
cat > "$YH/yohuman-approve-on.sh" <<'ONSH_EOF'
#!/bin/bash
touch "$HOME/.yohuman/approve-enabled"
echo "🟢 Two-way phone approval is ON. Approve/Reject right from your phone or watch."
ONSH_EOF
cat > "$YH/yohuman-approve-off.sh" <<'OFFSH_EOF'
#!/bin/bash
rm -f "$HOME/.yohuman/approve-enabled"
echo "⚪ Two-way OFF — notify-only (approve on the Mac)."
OFFSH_EOF
chmod +x "$YH/yohuman-approve-on.sh" "$YH/yohuman-approve-off.sh"

# Clean up any old ntfy listener from a previous (pre-app) install.
rm -f "$YH/yohuman-approval-listener.sh" 2>/dev/null || true
if [ -f "$HOME/Library/LaunchAgents/com.yohuman.listener.plist" ]; then
  launchctl unload -w "$HOME/Library/LaunchAgents/com.yohuman.listener.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.yohuman.listener.plist" 2>/dev/null || true
fi
pkill -f yohuman-approval-listener.sh 2>/dev/null || true

say "✅ scripts installed in $YH/"

# --- 5. Merge the global hooks into ~/.claude/settings.json (no clobber of your other settings) ---
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp="$(mktemp)"
jq \
  --arg pr   'bash "$HOME/.yohuman/yohuman-approval-hook.sh"' \
  --arg idle 'bash "$HOME/.yohuman/yohuman-push.sh" idle' \
  --arg stop 'bash "$HOME/.yohuman/yohuman-push.sh" stop' \
  --arg err  'bash "$HOME/.yohuman/yohuman-push.sh" error' '
  .hooks.PermissionRequest = [ { hooks: [ { type:"command", command:$pr, timeout:70 } ] } ]
  | .hooks.Notification    = [ { matcher:"idle_prompt", hooks: [ { type:"command", command:$idle } ] } ]
  | .hooks.Stop            = [ { hooks: [ { type:"command", command:$stop } ] } ]
  | .hooks.StopFailure     = [ { hooks: [ { type:"command", command:$err } ] } ]
  | .permissions.allow = ((.permissions.allow // []) + ["Bash(bash ~/.yohuman/yohuman-on.sh)","Bash(bash ~/.yohuman/yohuman-off.sh)"] | unique)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; say "❌ failed to update $SETTINGS"; exit 1; }
say "✅ global hooks installed in $SETTINGS"

# --- 5b. On/off toggle scripts + natural-language control ("Yo Human, I'm away") ---
cat > "$YH/yohuman-on.sh" <<'ON2_EOF'
#!/bin/bash
# Notifications ON (unmute) + a confirmation buzz so you KNOW it's live.
rm -f "$HOME/.yohuman/mute"
. "$HOME/.yohuman/config.sh" 2>/dev/null
URL="${YH_PUSH_URL:-https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push}"
CH="${YH_PUSH_CHANNEL:-}"; KEY="${YH_PUSH_KEY:-}"
jq -n --arg c "$CH" --arg b "You're on — I'll buzz you the moment Claude needs you." \
  '{channel:$c,title:"Yo Human",body:$b,category:"INFO"}' \
  | curl -s -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true
echo "🔔 Yo Human is ON — your phone will buzz when Claude needs you. (Check your phone for the confirmation.)"
ON2_EOF
cat > "$YH/yohuman-off.sh" <<'OFF2_EOF'
#!/bin/bash
touch "$HOME/.yohuman/mute"
echo "🔕 Yo Human is OFF — muted while you work. Say \"Yo Human, I'm away\" to turn it back on."
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
say "🎉 Done. RESTART Claude Code, then every project on this Mac buzzes your iPhone."
say ""
say "📲 PAIR YOUR PHONE — paste this channel code into the Yo Human app:"
say ""
say "        $CHANNEL"
say ""
say "   (Yo Human app → Add/Pair → paste the code. Get the app from TestFlight / the App Store.)"
say ""
say "Optional — two-way phone approval (Allow once / always / Reject):"
say "   turn ON:   bash ~/.yohuman/yohuman-approve-on.sh"
say "   turn OFF:  bash ~/.yohuman/yohuman-approve-off.sh"
say ""
say "Control it by just TALKING to Claude Code (any project):"
say "   \"Yo Human, I'm going for a walk\"  →  turns notifications ON"
say "   \"Yo Human, I'm back\" / \"quiet\"     →  mutes (do not disturb)"
say "(manual: touch ~/.yohuman/mute to mute, rm ~/.yohuman/mute to unmute)"
