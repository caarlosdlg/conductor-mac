#!/usr/bin/env node
import { loadConfig } from '../src/config.js';
import { Store } from '../src/store.js';
import { Engine } from '../src/engine.js';
import { importAll } from '../src/importer.js';

const [cmd, ...rest] = process.argv.slice(2);
const cfg = loadConfig();
const store = new Store();

if (cmd === 'import') {
  console.log(`importadas ${importAll(store, cfg.projects)} tareas`);
  store.flush();
} else if (cmd === 'add') {
  const [project, ...title] = rest;
  if (!cfg.projects.some((p) => p.id === project) || !title.length) {
    console.error(`uso: conductor add <${cfg.projects.map((p) => p.id).join('|')}> <título>`);
    process.exit(1);
  }
  const t = store.add({ project, title: title.join(' '), source: 'manual' });
  store.flush();
  console.log(`+ ${t.id} ${t.title}`);
} else if (cmd === 'clean') {
  console.log(new Engine(store, cfg).cleanupDone());
  store.flush();
  process.exit(0);
} else if (cmd === 'status') {
  for (const t of store.tasks) console.log(`${t.id}  ${t.status.padEnd(8)} ${t.phase.padEnd(8)} ctx ${String(t.ctxPct).padStart(2)}%  ${t.project}  ${t.title}`);
} else {
  console.error('uso: conductor import | clean | add <proyecto> <título> | status  (la interfaz es la app Conductor.app)');
  process.exit(1);
}
