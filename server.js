import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as sonos from './sonos.js';
import { mock } from './mock.js';

const dir = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 3000);
const DATA = process.env.SONOS_DATA ?? path.join(dir, 'presets.json');
let useMock = process.env.SONOS_MOCK === '1';
let seedIp = process.env.SONOS_IP ?? null;

const DEFAULT_PRESETS = () => [
  { id: 'normal', name: 'Normal', volume: 30, bass: 0, treble: 0, loudness: false },
  { id: 'bass', name: 'Bass+', volume: 40, bass: 6, treble: 1, loudness: true },
  { id: 'nacht', name: 'Nacht', volume: 12, bass: -3, treble: -1, loudness: false },
  { id: 'party', name: 'Party', volume: 60, bass: 8, treble: 4, loudness: true },
];

// Persistenz: { [groupKey]: { presets: [...], active: id|null } }
let store = {};
try { store = JSON.parse(await fs.readFile(DATA, 'utf8')); } catch {}
const save = () => fs.writeFile(DATA, JSON.stringify(store, null, 2));
const entry = (key) => (store[key] ??= { presets: DEFAULT_PRESETS(), active: null });
// Schlüssel = Menge der Lautsprecher-IDs: stabil bei Umbenennung, unabhängig von Reihenfolge/Koordinator
const groupKey = (g) => g.members.map((m) => m.id).sort().join('|');

async function topology() {
  if (useMock) return mock.topology();
  if (!seedIp) {
    const ips = await sonos.discover();
    if (!ips.length) throw new Error('Keine Sonos-Lautsprecher gefunden. Setze SONOS_IP=<ip> oder starte mit "npm run demo".');
    seedIp = ips[0];
  }
  try { return await sonos.getTopology(seedIp); } catch (e) { seedIp = process.env.SONOS_IP ?? null; throw e; }
}
const readSpeaker = (m) => (useMock ? mock.read(m.ip) : sonos.readSpeaker(m.ip));
const applySettings = (g, s) => (useMock ? mock.apply(g, s) : sonos.applyToGroup(g, s));

async function describe() {
  const groups = await topology();
  return Promise.all(groups.map(async (g) => {
    const key = groupKey(g);
    const states = await Promise.all(g.members.map(readSpeaker));
    const coordState = states[Math.max(0, g.members.findIndex((m) => m.id === g.coordinator))];
    const volume = useMock ? await mock.readGroupVolume(g) : await sonos.readGroupVolume((g.members.find((m) => m.id === g.coordinator) ?? g.members[0]).ip);
    const { presets, active } = entry(key);
    return { key, name: g.members.map((m) => m.name).join(' + '), members: g.members.map((m) => m.name), grouped: g.members.length > 1,
      current: { volume, bass: coordState.bass, treble: coordState.treble, loudness: coordState.loudness }, presets, active };
  }));
}
async function findGroup(key) {
  const g = (await topology()).find((x) => groupKey(x) === key);
  if (!g) throw Object.assign(new Error('Gruppe nicht gefunden (Gruppierung geändert?)'), { status: 404 });
  return g;
}

const num = (v, lo, hi) => (v == null ? undefined : Math.min(hi, Math.max(lo, Math.round(Number(v)))));
const clean = (b) => ({ volume: num(b.volume, 0, 100), bass: num(b.bass, -10, 10), treble: num(b.treble, -10, 10), loudness: b.loudness == null ? undefined : !!b.loudness });

const routes = {
  'GET /api/groups': async () => ({ mock: useMock, groups: await describe() }),
  // Manuelle Einstellung (Slider) – hebt das aktive Preset auf
  'POST /api/apply': async (b) => {
    const g = await findGroup(b.key);
    await applySettings(g, clean(b));
    entry(b.key).active = null; await save();
    return { ok: true };
  },
  // Preset-Switch
  'POST /api/preset/apply': async (b) => {
    const e = entry(b.key); const p = e.presets.find((x) => x.id === b.presetId);
    if (!p) throw Object.assign(new Error('Preset nicht gefunden'), { status: 404 });
    await applySettings(await findGroup(b.key), clean(p));
    e.active = p.id; await save();
    return { ok: true };
  },
  'POST /api/preset/save': async (b) => {
    const e = entry(b.key); const name = String(b.name ?? '').trim().slice(0, 24);
    if (!name) throw Object.assign(new Error('Name fehlt'), { status: 400 });
    const p = { id: Date.now().toString(36), name, ...Object.fromEntries(Object.entries(clean(b)).filter(([, v]) => v !== undefined)) };
    e.presets.push(p); e.active = p.id; await save();
    return { ok: true, preset: p };
  },
  'POST /api/preset/delete': async (b) => {
    const e = entry(b.key); e.presets = e.presets.filter((x) => x.id !== b.presetId);
    if (e.active === b.presetId) e.active = null; await save();
    return { ok: true };
  },
};

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };
export const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
  const handler = routes[`${req.method} ${url.pathname}`];
  if (handler) {
    try {
      let body = {};
      if (req.method === 'POST') { let raw = ''; for await (const c of req) raw += c; body = raw ? JSON.parse(raw) : {}; }
      return send(200, await handler(body));
    } catch (e) { return send(e.status ?? 502, { error: e.message }); }
  }
  if (req.method !== 'GET') return send(405, { error: 'Method not allowed' });
  const file = path.join(dir, 'public', url.pathname === '/' ? 'index.html' : url.pathname);
  if (!file.startsWith(path.join(dir, 'public'))) return send(403, { error: 'Forbidden' });
  try { const data = await fs.readFile(file); res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream' }); res.end(data); }
  catch { send(404, { error: 'Not found' }); }
});

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  server.listen(PORT, '0.0.0.0', () => console.log(`Sonossounds läuft auf http://localhost:${PORT}${useMock ? '  (Demo-Modus, simulierte Lautsprecher)' : ''}`));
}
