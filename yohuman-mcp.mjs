#!/usr/bin/env node
// Yo Human — Claude Desktop / Cowork MCP plug-in (Phase 0+).
// Zero dependencies. Speaks MCP over newline-delimited JSON-RPC on stdio.
// Reuses our existing ntfy backend: notifications go to the user's phone; two-way
// approvals use a non-blocking POLL pattern (fire alert -> check_approval until decided)
// to stay under Claude Desktop's ~60s tool-call timeout.
//
// Config via env (set in the Desktop Extension / claude_desktop_config.json):
//   YH_NTFY_SERVER     (default https://ntfy.sh)
//   YH_NOTIFY_CHANNEL  (the topic the user's phone is subscribed to)
//   YH_COMMAND_CHANNEL (the private topic the Allow/Reject buttons post to)

import { writeFileSync, existsSync, rmSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const NTFY   = process.env.YH_NTFY_SERVER    || 'https://ntfy.sh';
const NOTIFY = process.env.YH_NOTIFY_CHANNEL  || '';
const CMD    = process.env.YH_COMMAND_CHANNEL || '';

const STATE_DIR = join(homedir(), '.yohuman-cowork');
const MUTE_FILE = join(STATE_DIR, 'mute');

const isMuted = () => existsSync(MUTE_FILE);
function setMute(on) {
  try { mkdirSync(STATE_DIR, { recursive: true }); } catch {}
  if (on) writeFileSync(MUTE_FILE, String(Date.now()));
  else if (existsSync(MUTE_FILE)) rmSync(MUTE_FILE);
}

async function ntfyPost(channel, body, headers) {
  try {
    const res = await fetch(`${NTFY}/${channel}`, { method: 'POST', headers, body });
    return res.ok;
  } catch { return false; }
}

// ---- notification helpers (the ntfy backend, wrapped as plug-in actions) ----
async function sendNotify(message, type) {
  if (!NOTIFY) return { ok: false, reason: 'No notify channel configured (set YH_NOTIFY_CHANNEL).' };
  if (isMuted()) return { ok: true, muted: true };
  // NOTE: Title is an HTTP header → must be plain ASCII (no em dashes / emoji). Emoji is fine in the body.
  const map = {
    done:  ['Yo Human - done',  'white_check_mark', 'default'],
    error: ['Yo Human - error', 'rotating_light',   'high'],
    info:  ['Yo Human',         'speech_balloon',   'default'],
  };
  const [title, tag, prio] = map[type] || map.info;
  const ok = await ntfyPost(NOTIFY, message, { Title: title, Tags: tag, Priority: prio });
  return { ok };
}

async function sendApproval(summary) {
  if (!NOTIFY || !CMD) return { ok: false, reason: 'Channels not configured (need YH_NOTIFY_CHANNEL + YH_COMMAND_CHANNEL).' };
  const token = String(Math.floor(Date.now() / 1000));
  if (isMuted()) return { ok: true, muted: true, token };
  const cmdUrl = `${NTFY}/${CMD}`;
  const actions =
    `http, Allow once, ${cmdUrl}, method=POST, body=allowonce, clear=true; ` +
    `http, Allow always, ${cmdUrl}, method=POST, body=allowalways, clear=true; ` +
    `http, Reject, ${cmdUrl}, method=POST, body=reject, clear=true`;
  const ok = await ntfyPost(NOTIFY, `🔐 ${summary}`, {
    Title: 'Approve in Cowork?', Priority: 'max', Tags: 'lock', Actions: actions,
  });
  return { ok, token };
}

async function checkApproval(token) {
  if (!CMD) return { status: 'error', reason: 'No command channel configured.' };
  let text = '';
  try {
    // poll=1 returns cached messages since `token` and closes immediately (non-blocking).
    const res = await fetch(`${NTFY}/${CMD}/json?since=${encodeURIComponent(String(token))}&poll=1`);
    if (!res.ok) return { status: 'pending' };
    text = await res.text();
  } catch { return { status: 'pending' }; }

  let decision = '';
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      const o = JSON.parse(line);
      if (o.event === 'message' && ['allowonce', 'allowalways', 'reject'].includes(o.message)) decision = o.message;
    } catch {}
  }
  if (!decision) return { status: 'pending' };

  const friendly = decision === 'allowonce'   ? '✅ Got it — allowing once. Proceeding.'
                 : decision === 'allowalways' ? "✅ Got it — allowing always. Won't ask again."
                 :                              '🚫 Got it — rejected. Stopping.';
  await ntfyPost(NOTIFY, friendly, { Title: 'Yo Human', Tags: 'white_check_mark', Priority: 'low' });
  return { status: decision === 'reject' ? 'rejected' : 'approved', decision };
}

// ---- tool catalog (descriptions carry the "always call me" guidance: Lever A) ----
const TOOLS = [
  {
    name: 'notify',
    description:
      "Send a push notification to the user's phone. ALWAYS call this when you finish a task or want " +
      "to update the user (e.g. 'Finished the report'). type='done' when a task completes, 'error' on " +
      "failure, 'info' otherwise.",
    inputSchema: { type: 'object', properties: { message: { type: 'string' }, type: { type: 'string', enum: ['done', 'error', 'info'] } }, required: ['message'] },
  },
  {
    name: 'request_approval',
    description:
      "Ask the user to approve an action from their phone. ALWAYS call this BEFORE doing anything risky " +
      "(deleting, sending, overwriting, spending). Give a one-line summary. Returns a token; then call " +
      "check_approval with that token every few seconds until it returns 'approved' or 'rejected'.",
    inputSchema: { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] },
  },
  {
    name: 'check_approval',
    description:
      "Check whether the user has approved/rejected a pending request. Call this every few seconds after " +
      "request_approval, passing its token, until status is 'approved' or 'rejected' (not 'pending'). " +
      "If approved, proceed; if rejected, stop. Returns quickly.",
    inputSchema: { type: 'object', properties: { token: { type: ['string', 'number'] } }, required: ['token'] },
  },
  { name: 'mute',   description: "Silence notifications. Call when the user says they're away / stepping out / 'mute'.", inputSchema: { type: 'object', properties: {} } },
  { name: 'unmute', description: "Resume notifications. Call when the user says they're back / 'unmute'.",               inputSchema: { type: 'object', properties: {} } },
];

async function callTool(name, args) {
  args = args || {};
  switch (name) {
    case 'notify': {
      const r = await sendNotify(String(args.message || ''), args.type);
      return r.muted ? 'Muted — not sent.' : (r.ok ? 'Sent to phone. ✅' : `Failed: ${r.reason || 'network error'}`);
    }
    case 'request_approval': {
      const r = await sendApproval(String(args.summary || ''));
      if (r.muted) return `Muted — treat as auto-approved (token=${r.token}).`;
      return r.ok
        ? `Approval requested on the phone. token=${r.token}. Now call check_approval with this token every few seconds until it returns approved or rejected.`
        : `Failed: ${r.reason}`;
    }
    case 'check_approval':
      return JSON.stringify(await checkApproval(args.token));
    case 'mute':   setMute(true);  return 'Muted. The phone will stay quiet until you unmute.';
    case 'unmute': setMute(false); return 'Unmuted. Notifications resume.';
    default: return `Unknown tool: ${name}`;
  }
}

// ---- MCP JSON-RPC over newline-delimited stdio ----
const send = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');

async function handle(line) {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  const { id, method, params } = msg;

  if (method === 'initialize') {
    send({ jsonrpc: '2.0', id, result: {
      protocolVersion: (params && params.protocolVersion) || '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'yohuman', version: '0.1.0' },
    } });
    return;
  }
  if (method === 'notifications/initialized' || method === 'initialized') return; // no response
  if (method === 'tools/list') { send({ jsonrpc: '2.0', id, result: { tools: TOOLS } }); return; }
  if (method === 'tools/call') {
    try {
      const text = await callTool(params && params.name, params && params.arguments);
      send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: String(text) }] } });
    } catch (e) {
      send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Error: ${e.message}` }], isError: true } });
    }
    return;
  }
  if (method === 'ping') { send({ jsonrpc: '2.0', id, result: {} }); return; }
  if (id !== undefined && id !== null) send({ jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } });
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (line) handle(line);
  }
});
process.stdin.on('end', () => process.exit(0));
