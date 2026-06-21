#!/usr/bin/env node
// Yo Human — Claude Desktop / Cowork MCP plug-in.
// Zero dependencies. Speaks MCP over newline-delimited JSON-RPC on stdio.
//
// Delivery: Supabase `push` function → Apple Push (APNs) → the Yo Human iOS app.
// (No ntfy.) Two-way approvals use a non-blocking POLL pattern (request_approval ->
// check_approval until decided) to stay under Claude Desktop's ~60s tool-call timeout.
//
// Config via env (set in the Desktop Extension / claude_desktop_config.json):
//   YH_CHANNEL   — the channel code you paste into the Yo Human app (required)
//   YH_PUSH_URL  — default https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push
//   YH_PUSH_KEY  — Supabase publishable key (browser-safe, RLS-protected)

import { writeFileSync, existsSync, rmSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const PUSH_URL = process.env.YH_PUSH_URL || 'https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push';
const KEY      = process.env.YH_PUSH_KEY || 'sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1';
const CHANNEL  = process.env.YH_CHANNEL  || process.env.YH_NOTIFY_CHANNEL || '';
const RPC      = PUSH_URL.replace(/\/functions\/v1\/push$/, '/rest/v1/rpc');
const HEADERS  = { 'Content-Type': 'application/json', apikey: KEY, Authorization: `Bearer ${KEY}` };

// Injected into the model's system prompt every session (MCP `instructions`). This is the closest
// thing to a "hook" Cowork/Chat allows — a standing rule to proactively buzz the user's phone.
const YH_INSTRUCTIONS = [
  "Yo Human is the user's phone + Apple Watch notification bridge. The user is frequently AWAY from their screen while you work, and installed this specifically so they can step away and trust you'll reach them. Treat keeping them informed as PART OF doing the task, never optional:",
  "• When you FINISH a task or a multi-step job, ALWAYS call the `notify` tool (type=\"done\") so their phone buzzes — even if they didn't ask. That is the entire purpose of this tool.",
  "• If you hit an ERROR or get BLOCKED and cannot continue, call `notify` (type=\"error\").",
  "• BEFORE any destructive, irreversible, sending, spending, deleting, or external action, call `request_approval` with a one-line summary, then call `check_approval` every few seconds until it returns approved or rejected — do NOT proceed until approved.",
  "Only skip notifying for trivial, real-time back-and-forth where the user is obviously watching the screen as you respond.",
].join("\n");

const STATE_DIR = join(homedir(), '.yohuman-cowork');
const MUTE_FILE = join(STATE_DIR, 'mute');

const isMuted = () => existsSync(MUTE_FILE);
function setMuteLocal(on) {
  try { mkdirSync(STATE_DIR, { recursive: true }); } catch {}
  if (on) writeFileSync(MUTE_FILE, String(Date.now()));
  else if (existsSync(MUTE_FILE)) rmSync(MUTE_FILE);
}

// ---- Supabase backend (push function + decision RPCs) ----
async function pushSend({ title, body, category = 'INFO', request_id }) {
  if (!CHANNEL) return { ok: false, reason: 'No channel configured (set YH_CHANNEL to your app pairing code).' };
  const payload = { channel: CHANNEL, title, body, category };
  if (request_id) payload.request_id = request_id;
  try {
    const res = await fetch(PUSH_URL, { method: 'POST', headers: HEADERS, body: JSON.stringify(payload) });
    return { ok: res.ok };
  } catch { return { ok: false, reason: 'network error' }; }
}

async function getDecision(requestId) {
  try {
    const res = await fetch(`${RPC}/get_decision`, { method: 'POST', headers: HEADERS, body: JSON.stringify({ p_request_id: String(requestId) }) });
    if (!res.ok) return '';
    const t = (await res.text()).replace(/["\s[\]]/g, '');
    return ['allowonce', 'allowalways', 'reject'].includes(t) ? t : '';
  } catch { return ''; }
}

// Server-side channel mute so EVERY agent on this channel goes quiet (honored by the push fn).
async function setMuteServer(muted) {
  if (!CHANNEL) return;
  try { await fetch(`${RPC}/set_channel_mute`, { method: 'POST', headers: HEADERS, body: JSON.stringify({ p_channel: CHANNEL, p_muted: muted }) }); } catch {}
}

// ---- notification helpers (wrapped as plug-in actions) ----
async function sendNotify(message, type) {
  if (!CHANNEL) return { ok: false, reason: 'No channel configured (set YH_CHANNEL).' };
  if (isMuted()) return { ok: true, muted: true };
  const titles = { done: 'Yo Human — done', error: 'Yo Human — error', info: 'Yo Human' };
  return pushSend({ title: titles[type] || titles.info, body: message, category: 'INFO' });
}

async function sendApproval(summary) {
  const token = `cowork-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  if (!CHANNEL) return { ok: false, reason: 'No channel configured (set YH_CHANNEL).' };
  if (isMuted()) return { ok: true, muted: true, token };
  const r = await pushSend({ title: 'Approve in Cowork?', body: summary, category: 'APPROVAL', request_id: token });
  return { ok: r.ok, token, reason: r.reason };
}

async function checkApproval(token) {
  const decision = await getDecision(token);
  if (!decision) return { status: 'pending' };
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
    case 'mute':   setMuteLocal(true);  await setMuteServer(true);  return 'Muted. The phone will stay quiet until you unmute.';
    case 'unmute': setMuteLocal(false); await setMuteServer(false); return 'Unmuted. Notifications resume.';
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
      serverInfo: { name: 'yohuman', version: '0.3.0' },
      instructions: YH_INSTRUCTIONS,
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
