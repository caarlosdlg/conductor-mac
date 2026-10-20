import fs from 'node:fs';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { PATHS, HOME } from './config.js';
import { runClaude, parsePhaseResult } from './worker.js';
import { PHASES, buildPrompt, handoffPrompt } from './prompts.js';
import { admin } from './admin.js';

const git = (cwd, ...a) => execFileSync('git', ['-C', cwd, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const isRepo = (p) => { try { return git(p, 'rev-parse', '--is-inside-work-tree') === 'true'; } catch { return false; } };

/** Planificador + ejecutor de pipelines (plan → validar → construir → probar → desplegar). */
export class Engine extends EventEmitter {
  constructor(store, cfg) {
    super();
    this.store = store;
    this.cfg = cfg;
    this.children = new Map();
    this.running = new Set();
    this.stopping = new Set();
    this.limits = this.loadLimits();
    this.timer = setInterval(() => this.tick(), 1000);
  }

  // ── Límites de uso del plan (ventanas de 5 h y 7 d) ──────────────────
  // Claude emite `rate_limit_event` en cada sesión; guardamos el último valor visto.
  loadLimits() {
    try { return JSON.parse(fs.readFileSync(path.join(HOME, 'limits.json'), 'utf8')); } catch { return null; }
  }
  recordLimits(info) {
    const w = info?.unifiedWindows;
    if (!w) return;
    this.limits = { five_hour: w.five_hour || null, seven_day: w.seven_day || null, status: info.status || 'allowed', updatedAt: Date.now() };
    try { fs.writeFileSync(path.join(HOME, 'limits.json'), JSON.stringify(this.limits)); } catch {}
    this.store.touch();
  }
  /** ¿Se alcanzó un límite? Hasta cuándo (ms) conviene no lanzar trabajo nuevo. */
  get blockedUntil() {
    const l = this.limits;
    if (!l || l.status === 'allowed' || l.status === 'allowed_warning') return 0;
    const reset = Math.max(l.five_hour?.resetsAt || 0, 0) * 1000;
    return reset > Date.now() ? reset : 0;
  }
  /** Consulta mínima (haiku, ~$0.03) para refrescar los límites cuando no hay workers que los reporten. */
  async refreshLimits() {
    if (this._probing) return;
    this._probing = true;
    try {
      await runClaude({ prompt: 'ok', cwd: HOME, bin: this.cfg.claudeBin, model: 'haiku', mode: 'default', allowedTools: [], disallowedTools: [],
        onEvent: (ev) => { if (ev.kind === 'rate') this.recordLimits(ev.info); } });
    } finally { this._probing = false; }
  }

  project(task) { return this.cfg.projects.find((p) => p.id === task.project); }
  taskDir(task) { const d = path.join(PATHS.tasks, task.id); fs.mkdirSync(d, { recursive: true }); return d; }
  get runningCount() { return this.running.size; }

  // ── Acciones del usuario ────────────────────────────────────────────
  start(ids) {
    for (const id of ids) {
      const t = this.store.get(id);
      if (!t || ['running', 'queued', 'done'].includes(t.status)) continue;
      t.status = 'queued';
      t.queuedAt = Date.now();
      t.gate = null;
      this.store.touch();
    }
    this.tick();
  }
  stop(id) {
    const t = this.store.get(id);
    if (!t) return;
    if (t.status === 'queued') { t.status = 'paused'; this.store.touch(); return; }
    if (!this.running.has(id)) return;
    this.stopping.add(id);
    this.children.get(id)?.kill('SIGTERM');
  }
  stopAll() { for (const id of [...this.running]) this.stop(id); }
  approve(id) {
    const t = this.store.get(id);
    if (t?.status !== 'waiting') return;
    if (t.gate?.type === 'deploy') t.deployApproved = true;
    this.start([id]);
  }
  guide(id, text) {
    const t = this.store.get(id);
    if (!t) return;
    t.guidance = text;
    if (t.status === 'waiting' || t.status === 'failed') { t.status = 'paused'; this.start([id]); }
    this.store.touch();
  }
  setMaxParallel(n) { this.cfg.maxParallel = Math.max(1, Math.min(12, n)); this.store.touch(); this.tick(); }

  // ── Planificador ────────────────────────────────────────────────────
  tick() {
    if (this.blockedUntil) return; // límite del plan alcanzado: se reanuda solo al reiniciarse la ventana
    const queued = this.store.tasks.filter((t) => t.status === 'queued' && !this.running.has(t.id))
      .sort((a, b) => (a.queuedAt || 0) - (b.queuedAt || 0));
    for (const t of queued) {
      if (this.running.size >= this.cfg.maxParallel) break;
      const p = this.project(t);
      if (!p) { this.fail(t, `proyecto desconocido: ${t.project}`); continue; }
      // Sin git no hay worktrees: una sola tarea a la vez en ese proyecto.
      if (!isRepo(p.path) && [...this.running].some((id) => this.store.get(id).project === t.project)) continue;
      this.running.add(t.id);
      t.status = 'running';
      t.startedAt ||= Date.now();
      this.store.touch();
      this.run(t, p).catch((e) => this.fail(t, String(e?.message || e))).finally(() => {
        this.running.delete(t.id);
        this.children.delete(t.id);
        this.stopping.delete(t.id);
        this.store.touch();
        this.tick();
      });
    }
  }

  fail(t, note) {
    t.status = 'failed';
    t.gate = { type: 'failed', note };
    this.store.log(t, `✗ ${note}`);
  }

  workspace(task, project) {
    if (task.workspace && fs.existsSync(task.workspace)) return task.workspace;
    if (!isRepo(project.path)) { task.workspace = project.path; return task.workspace; }
    const wt = path.join(PATHS.worktrees, `${project.id}-${task.id}`);
    this.assertWritableRepo(project);
    task.branch = `conductor/${task.id}`;
    task.baseBranch = git(project.path, 'branch', '--show-current') || project.baseBranch;
    const branchExists = () => { try { git(project.path, 'show-ref', '--verify', '--quiet', `refs/heads/${task.branch}`); return true; } catch { return false; } };
    if (branchExists()) git(project.path, 'worktree', 'add', wt, task.branch); // reanudación: la rama ya existía
    else {
      try { git(project.path, 'rev-parse', '--verify', 'HEAD'); }
      catch { throw new Error(`«${project.name}» no tiene ningún commit todavía: haz un commit inicial para poder aislar tareas en ramas.`); }
      git(project.path, 'worktree', 'add', '-b', task.branch, wt, 'HEAD');
    }
    this.store.log(task, `⎇ worktree ${task.branch}`);
    task.workspace = wt;
    return wt;
  }

  /** Git necesita escribir en .git del repo (ramas, worktrees, objetos); si algo es de root, falla con mensajes crípticos. */
  assertWritableRepo(project) {
    const common = path.resolve(project.path, git(project.path, 'rev-parse', '--git-common-dir'));
    const bad = ['refs/heads', 'objects', 'worktrees'].map((d) => path.join(common, d))
      .filter((d) => fs.existsSync(d)).filter((d) => { try { fs.accessSync(d, fs.constants.W_OK); return false; } catch { return true; } });
    if (bad.length) {
      throw new Error(`No puedo escribir en el .git de «${project.name}» (${path.basename(bad[0])} pertenece a otro usuario, probablemente root). ` +
        `Corrígelo con: sudo chown -R $(whoami) "${project.path}"  y reintenta.`);
    }
  }

  // ── Pipeline de una tarea ───────────────────────────────────────────
  async run(task, project) {
    const cwd = this.workspace(task, project);
    this.store.log(task, `▶ ${task.phase}`);
    while (task.phase !== 'done') {
      const phase = task.phase;
      if (phase === 'deploy' && !task.deployApproved) {
        this.store.log(task, '⚖ admin revisando deploy');
        const v = await admin.review(this, task, project, { type: 'deploy' });
        if (this.stopping.has(task.id)) { task.status = 'paused'; return; }
        if (v.decision === 'reject') { this.store.log(task, `⏭ deploy omitido: ${v.reason}`); task.phase = 'done'; break; }
        if (v.decision === 'ask') {
          task.status = 'waiting';
          task.gate = { type: 'deploy', note: v.reason };
          this.store.log(task, `⏸ esperando tu aprobación de deploy: ${v.reason}`);
          return;
        }
        this.store.log(task, `⚖ admin aprobó deploy: ${v.reason}`);
      }
      const r = await this.runPhase(task, project, cwd, phase);
      if (r.aborted) { task.status = 'paused'; this.store.log(task, '■ detenida'); return; }
      if (r.status === 'OK') {
        this.store.log(task, `✓ ${phase}${r.note ? ': ' + r.note : ''}`);
        task.phase = PHASES[PHASES.indexOf(phase) + 1] || 'done';
        task.sessionId = null; task.ctxPct = 0; task.guidance = null;
        this.store.touch();
      } else if (r.status === 'FAILED' && phase === 'test' && task.loops < this.cfg.maxFixLoops) {
        task.loops++;
        task.guidance = `Las pruebas fallaron (intento ${task.loops}): ${r.note}`;
        this.store.log(task, `↺ test falló → volver a construir (${task.loops}/${this.cfg.maxFixLoops})`);
        task.phase = 'build'; task.sessionId = null; task.ctxPct = 0;
      } else {
        const blocked = r.status === 'BLOCKED';
        this.store.log(task, `${blocked ? '⏸' : '✗'} ${phase}: ${r.note}`);
        this.store.log(task, '⚖ admin evaluando');
        const v = await admin.review(this, task, project, { type: blocked ? 'blocked' : 'failed', note: r.note });
        if (this.stopping.has(task.id)) { task.status = 'paused'; return; }
        if (v.decision === 'guide') {
          task.adminInterventions = (task.adminInterventions || 0) + 1;
          task.guidance = v.guidance;
          task.sessionId = null;
          this.store.log(task, `⚖ admin (${task.adminInterventions}/${this.cfg.maxAdminInterventions}): ${v.guidance.slice(0, 160)}`);
          continue; // reintenta la misma fase con la indicación
        }
        task.status = blocked ? 'waiting' : 'failed';
        task.gate = { type: blocked ? 'blocked' : 'failed', note: v.reason || r.note };
        this.store.log(task, `⚑ escalado a ti: ${v.reason || r.note}`);
        return;
      }
    }
    task.status = 'done';
    task.finishedAt = Date.now();
    this.store.log(task, '★ tarea completada');
  }

  async runPhase(task, project, cwd, phase) {
    const dir = this.taskDir(task);
    const { ctxWindow, ctxLimit, maxRotationsPerPhase: maxRot } = this.cfg;
    const handoffFile = path.join(dir, 'HANDOFF.md');
    const base = {
      cwd, taskId: task.id, bin: this.cfg.claudeBin, model: this.cfg.models[phase] || undefined,
      mode: this.cfg.permissionMode, addDirs: [dir],
      allowedTools: this.cfg.allowedTools, disallowedTools: this.cfg.disallowedTools,
      onSpawn: (c) => this.children.set(task.id, c),
    };
    const events = (ev) => {
      if (ev.kind === 'rate') this.recordLimits(ev.info);
      else if (ev.kind === 'init') { task.sessionId = ev.sessionId; task.sessionPhase = phase; }
      else if (ev.kind === 'ctx') { task.ctxPct = Math.round((ev.tokens / ctxWindow) * 100); this.store.touch(); }
      else if (ev.kind === 'tool') this.store.log(task, ev.text);
      else if (ev.kind === 'text') for (const l of ev.text.split('\n').filter(Boolean).slice(0, 4)) this.store.log(task, '· ' + l.slice(0, 200));
    };

    for (let rot = 0; rot <= maxRot; rot++) {
      const resume = rot === 0 && task.sessionId && task.sessionPhase === phase && task.ctxPct < ctxLimit * 100 ? task.sessionId : null;
      const prompt = resume
        ? `${task.guidance ? `INDICACIÓN DEL HUMANO/ADMIN (prioridad alta, resuelve tu bloqueo): ${task.guidance}\n` : ''}Continúa exactamente donde quedaste. Recuerda terminar con la línea PHASE_RESULT.`
        : buildPrompt(task, project, phase, {
            dir, cwd, branch: task.branch, guidance: task.guidance,
            handoffExists: fs.existsSync(handoffFile), testCmd: project.testCmd,
          });
      if (!resume) { task.sessions++; task.ctxPct = 0; }
      const out = await runClaude({ ...base, prompt, resume, ctxLimitTokens: ctxWindow * ctxLimit, onEvent: events });
      task.cost += out.cost;
      if (this.stopping.has(task.id)) return { aborted: true };

      if (out.rotate) {
        this.store.log(task, `↻ contexto ≥ ${Math.round(ctxLimit * 100)}% → handoff y sesión nueva (${rot + 1})`);
        await runClaude({ ...base, prompt: handoffPrompt(dir), resume: out.sessionId, ctxLimitTokens: 0, onEvent: () => {} });
        task.sessionId = null;
        continue;
      }
      const pr = parsePhaseResult(out.result);
      if (pr) return pr;
      if (out.isError || out.code) return { status: 'FAILED', note: (out.stderr || out.result || `claude salió con código ${out.code}`).slice(-300) };
      return { status: 'BLOCKED', note: `sin PHASE_RESULT; último mensaje: ${out.result.slice(-200)}` };
    }
    return { status: 'FAILED', note: `más de ${maxRot} rotaciones de contexto en la fase ${phase}` };
  }

  // ── Limpieza ────────────────────────────────────────────────────────
  /** Quita el worktree de una tarea terminada. La rama se borra sólo si ya está integrada. */
  cleanup(task) {
    if (this.running.has(task.id) || !task.workspace || task.workspace === this.project(task)?.path) return 'nada que limpiar';
    const p = this.project(task);
    try { git(p.path, 'worktree', 'remove', '--force', task.workspace); } catch (e) { return `no pude quitar el worktree: ${e.message.split('\n')[0]}`; }
    task.workspace = null;
    let note = 'worktree eliminado';
    try { git(p.path, 'branch', '-d', task.branch); note += `, rama ${task.branch} borrada (integrada)`; }
    catch { note += `, rama ${task.branch} conservada (sin integrar)`; }
    this.store.touch();
    return note;
  }
  cleanupDone() {
    const done = this.store.tasks.filter((t) => t.status === 'done' && t.workspace);
    return `${done.length} tarea(s): ` + (done.map((t) => this.cleanup(t)).join('; ') || 'nada');
  }

  // ── Consola interactiva ─────────────────────────────────────────────
  openTerminal(task) {
    const cwd = task.workspace || this.project(task)?.path;
    if (!cwd) return;
    const cmd = `cd ${JSON.stringify(cwd)} && ${task.sessionId ? `claude --resume ${task.sessionId}` : 'claude'}`;
    const esc = cmd.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    execFileSync('osascript', ['-e', `tell application "Terminal" to do script "${esc}"`, '-e', 'tell application "Terminal" to activate']);
  }

  dispose() { clearInterval(this.timer); this.stopAll(); this.store.flush(); }
}
