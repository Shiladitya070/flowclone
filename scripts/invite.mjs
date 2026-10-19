#!/usr/bin/env node
// Invite friends to FlowClone with their own capped OpenRouter key.
//
// Each friend gets a separate key with a spending limit, so nobody can drain your credit, you can
// see usage per person, and you can revoke one friend without affecting anyone else. Their audio
// goes straight from their Mac to OpenRouter: nothing passes through you.
//
// Needs an OpenRouter *management* key (openrouter.ai/settings/management-keys) in .env:
//   OPENROUTER_MANAGEMENT_KEY=sk-or-v1-...
//
// Usage:
//   node scripts/invite.mjs create "Riya" [--limit 2.5]   → prints the invite message to send
//   node scripts/invite.mjs list                           → usage per friend
//   node scripts/invite.mjs revoke "Riya"                  → disables that friend's key

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const INSTALLER = "https://raw.githubusercontent.com/Shiladitya070/flowclone/main/site/install.sh";
const SITE = "https://github.com/Shiladitya070/flowclone";
const PREFIX = "FlowClone · ";
const API = "https://openrouter.ai/api/v1/keys";

function managementKey() {
  if (process.env.OPENROUTER_MANAGEMENT_KEY) return process.env.OPENROUTER_MANAGEMENT_KEY;
  try {
    const env = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", ".env"), "utf8");
    const m = env.match(/^OPENROUTER_MANAGEMENT_KEY=(.+)$/m);
    if (m) return m[1].trim();
  } catch {}
  console.error("Add OPENROUTER_MANAGEMENT_KEY=sk-or-v1-... to .env (create one at openrouter.ai/settings/management-keys).");
  process.exit(1);
}

async function api(method, path = "", body) {
  const res = await fetch(API + path, {
    method,
    headers: { Authorization: `Bearer ${managementKey()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${API + path} → ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}

async function friendKeys() {
  const { data = [] } = await api("GET");
  return data.filter((k) => k.name?.startsWith(PREFIX));
}

async function create(name, limit) {
  const json = await api("POST", "", { name: PREFIX + name, limit });
  const key = json.key ?? json.data?.key;
  if (!key) throw new Error("Key created but not returned: " + JSON.stringify(json).slice(0, 200));
  const deepLink = `flowclone://setup?key=${encodeURIComponent(key)}`;
  console.log(`Created a $${limit} key for ${name}.\n`);
  console.log("──────── send this to " + name + " ────────");
  console.log(`Hey! Try FlowClone, my dictation app for Mac: hold Fn, talk (English/Hindi/Bengali mixed is fine), and the text types itself.

1) Open Terminal and paste this one line (installs the app and sets up your invite):

curl -fsSL ${INSTALLER} | bash -s -- ${key}

2) Allow Microphone + Accessibility when it asks, then hold Fn anywhere and speak.

Your dictations go straight from your Mac to the transcription service with zero data retention. I only see how much credit is used, never what you say. More: ${SITE}

(Already installed? Just open this link instead: ${deepLink})`);
  console.log("──────────────────────────────────────");
}

async function list() {
  const keys = await friendKeys();
  if (!keys.length) return console.log("No FlowClone invites yet. Create one: node scripts/invite.mjs create \"Name\"");
  console.table(keys.map((k) => ({
    friend: k.name.slice(PREFIX.length),
    used: "$" + Number(k.usage ?? 0).toFixed(2),
    limit: k.limit == null ? "none" : "$" + Number(k.limit).toFixed(2),
    left: k.limit_remaining == null ? "-" : "$" + Number(k.limit_remaining).toFixed(2),
    status: k.disabled ? "revoked" : "active",
  })));
}

async function revoke(name) {
  const match = (await friendKeys()).filter((k) => k.name === PREFIX + name || k.hash === name);
  if (!match.length) throw new Error(`No invite named "${name}".`);
  for (const k of match) await api("PATCH", `/${k.hash}`, { disabled: true });
  console.log(`Revoked ${match.length} key(s) for ${name}. Their app will show an error on the next dictation.`);
}

const [cmd, arg, ...rest] = process.argv.slice(2);
const limitFlag = rest.indexOf("--limit");
const limit = limitFlag >= 0 ? Number(rest[limitFlag + 1]) : 2.5;

try {
  if (cmd === "create" && arg && limit > 0) await create(arg, limit);
  else if (cmd === "list") await list();
  else if (cmd === "revoke" && arg) await revoke(arg);
  else console.log('Usage:\n  node scripts/invite.mjs create "Name" [--limit 2.5]\n  node scripts/invite.mjs list\n  node scripts/invite.mjs revoke "Name"');
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
