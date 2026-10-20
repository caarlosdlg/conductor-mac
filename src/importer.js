import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const MD_FILES = ['TASKS.md', 'TODO.md', 'todo.md', '.planning/ROADMAP.md', 'docs/TODO.md'];
export const cleanTitle = (s) => s.replace(/\*\*|__|`/g, '').replace(/\s+/g, ' ').trim();
const h = (s) => crypto.createHash('sha1').update(s).digest('hex').slice(0, 10);

/** Lee tareas pendientes de cada proyecto: checkboxes `- [ ]` en markdown y orchestrator/tasks.json. */
export function scanProject(project) {
  const found = [];
  for (const root of [project.path, ...(project.scanPaths || [])]) found.push(...scanRoot(root));
  return found;
}

function scanRoot(root) {
  const found = [];
  for (const rel of MD_FILES) {
    const file = path.join(root, rel);
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*[-*]\s+\[ \]\s+(.+)$/);
      if (m) found.push({ title: cleanTitle(m[1]).slice(0, 140), source: `${rel}:${h(m[1])}` });
    }
  }
  const orch = path.join(root, 'orchestrator/tasks.json');
  if (fs.existsSync(orch)) {
    try {
      for (const t of JSON.parse(fs.readFileSync(orch, 'utf8')).tasks || []) {
        if (t.status && t.status !== 'pending') continue;
        found.push({ title: t.label || t.id, desc: t.description, source: `orchestrator:${t.id}` });
      }
    } catch {}
  }
  return found;
}

/** Importa sólo lo que aún no está en el store (dedupe por origen). Devuelve cuántas añadió. */
export function importAll(store, projects) {
  let n = 0;
  for (const p of projects) {
    if (!fs.existsSync(p.path)) continue;
    for (const f of scanProject(p)) {
      if (store.tasks.some((t) => t.project === p.id && t.source === f.source)) continue;
      store.add({ project: p.id, ...f });
      n++;
    }
  }
  return n;
}
