// Motor de Conductor como proceso sin interfaz. La app de Mac lo lanza y habla con él
// por stdio con JSON de una línea por mensaje.
//
//  motor → app:  {t:'state', tasks, cfg, running}  ·  {t:'event', kind, taskId, title, note}  ·  {t:'toast', msg}
//  app → motor:  {cmd:'start'|'stop'|'stopAll'|'approve'|'guide'|'add'|'remove'|'import'|'cleanup'|
//                      'cleanupAll'|'openTerminal'|'setConfig'|'resync', ...}
import readline from 'node:readline';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig, PATHS } from './config.js';
import { Store } from './store.js';
import { Engine } from './engine.js';
import { importAll } from './importer.js';

// Las apps de GUI heredan un PATH mínimo; `claude`, `git`, `node` y `vercel` viven en otros sitios.
const extra = [path.join(os.homedir(), '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'];
process.env.PATH = [...new Set([...extra, ...(process.env.PATH || '').split(':')])].join(':');

const cfg = loadConfig();
const store = new Store();
const engine = new Engine(store, cfg);
if (store.tasks.length === 0) importAll(store, cfg.projects);

const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const toast = (msg) => send({ t: 'toast', msg });

const prev = new Map(store.tasks.map((t) => [t.id, t.status]));
let scheduled = null;
function snapshot() {
  scheduled = null;
  for (const t of store.tasks) {
    const was = prev.get(t.id);
    if (was && was !== t.status && ['waiting', 'failed', 'done'].includes(t.status)) {
      send({ t: 'event', kind: t.status, taskId: t.id, title: t.title, note: t.gate?.note || '' });
    }
    prev.set(t.id, t.status);
  }
  send({ t: 'state', tasks: store.tasks, cfg, running: engine.runningCount, limits: engine.limits, blockedUntil: engine.blockedUntil });
}
store.on('change', () => { if (!scheduled) scheduled = setTimeout(snapshot, 250); });

function saveConfig(incoming) {
  const { claudeBin, permissionMode } = cfg; // no editables desde la app
  Object.assign(cfg, incoming, { claudeBin, permissionMode });
  cfg.maxParallel = Math.max(1, Math.min(12, Number(cfg.maxParallel) || 3));
  fs.writeFileSync(PATHS.config, JSON.stringify(cfg, null, 2));
  engine.tick();
  store.touch();
}

const handlers = {
  start: (m) => engine.start(m.ids || []),
  stop: (m) => (m.ids || []).forEach((id) => engine.stop(id)),
  stopAll: () => engine.stopAll(),
  approve: (m) => engine.approve(m.id),
  guide: (m) => engine.guide(m.id, m.text),
  add: (m) => store.add({ project: m.project, title: m.title, desc: m.desc || undefined, source: 'manual' }),
  remove: (m) => (m.ids || []).forEach((id) => { if (!engine.running.has(id)) store.remove(id); }),
  import: () => toast(`Importadas ${importAll(store, cfg.projects)} tareas nuevas`),
  cleanup: (m) => { const t = store.get(m.id); if (t) toast(engine.cleanup(t)); },
  cleanupAll: () => toast(engine.cleanupDone()),
  openTerminal: (m) => { const t = store.get(m.id); if (t) engine.openTerminal(t); },
  setConfig: (m) => saveConfig(m.cfg),
  resync: () => snapshot(),
  refreshLimits: () => engine.refreshLimits().catch(() => {}),
};

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  try { handlers[m.cmd]?.(m); } catch (e) { toast(`${m.cmd}: ${e.message}`); }
}).on('close', shutdown);

function shutdown() {
  engine.dispose();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('uncaughtException', (e) => { process.stderr.write(String(e.stack || e) + '\n'); });

snapshot();

if (!engine.limits || Date.now() - engine.limits.updatedAt > 10 * 60 * 1000) engine.refreshLimits().catch(() => {});
