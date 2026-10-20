import fs from 'node:fs';
import { EventEmitter } from 'node:events';
import crypto from 'node:crypto';
import { PATHS, ensureDirs } from './config.js';

export const newId = () => crypto.randomBytes(3).toString('hex');

/** Persistencia JSON simple con guardado diferido y evento 'change'. */
export class Store extends EventEmitter {
  constructor() {
    super();
    ensureDirs();
    this.tasks = [];
    try { this.tasks = JSON.parse(fs.readFileSync(PATHS.state, 'utf8')).tasks || []; } catch {}
    // Lo que estaba corriendo cuando se cerró la app se reanuda solo, desde su fase y sesión.
    // Sólo 'paused' (detenida a propósito con Detener) espera a que la inicies.
    for (const t of this.tasks) if (t.status === 'running' || t.status === 'queued') { t.status = 'queued'; t.queuedAt = Date.now(); }
    for (const t of this.tasks) t.title = t.title.replace(/\*\*|__|`/g, '').replace(/\s+/g, ' ').trim();
    this._timer = null;
  }
  get(id) { return this.tasks.find((t) => t.id === id); }
  add(t) {
    const task = {
      id: newId(), status: 'backlog', phase: 'plan', ctxPct: 0, sessions: 0, cost: 0,
      loops: 0, log: [], createdAt: Date.now(), ...t,
    };
    this.tasks.push(task);
    this.touch();
    return task;
  }
  remove(id) { this.tasks = this.tasks.filter((t) => t.id !== id); this.touch(); }
  log(task, line) {
    task.log.push(line);
    if (task.log.length > 120) task.log.splice(0, task.log.length - 120);
    try { fs.appendFileSync(this.logFile(task), line + '\n'); } catch {}
    this.touch();
  }
  logFile(task) {
    const d = `${PATHS.tasks}/${task.id}`;
    fs.mkdirSync(d, { recursive: true });
    return `${d}/log.txt`;
  }
  touch() {
    this.emit('change');
    clearTimeout(this._timer);
    this._timer = setTimeout(() => this.flush(), 400);
  }
  flush() {
    try { fs.writeFileSync(PATHS.state, JSON.stringify({ tasks: this.tasks }, null, 1)); } catch {}
  }
}
