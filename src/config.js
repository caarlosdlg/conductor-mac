import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const HOME = process.env.CONDUCTOR_HOME || path.join(os.homedir(), '.conductor');
export const PATHS = {
  config: path.join(HOME, 'config.json'),
  state: path.join(HOME, 'state.json'),
  tasks: path.join(HOME, 'tasks'),
  worktrees: path.join(HOME, 'worktrees'),
};

export const DEFAULTS = {
  maxParallel: 3,
  // Se rota a una sesión nueva al alcanzar este % de la ventana de contexto.
  ctxLimit: 0.4,
  ctxWindow: 200000,
  maxRotationsPerPhase: 6,
  maxFixLoops: 2,
  // Agente admin: decide ante bloqueos/fallos y revisa riesgo antes de un deploy automático.
  adminAgent: true,
  adminModel: null,
  maxAdminInterventions: 3,
  claudeBin: 'claude',
  // acceptEdits + Bash permitido; los comandos destructivos quedan bloqueados abajo.
  permissionMode: 'acceptEdits',
  allowedTools: ['Bash', 'Edit', 'Write', 'Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch', 'Task'],
  disallowedTools: [
    'Bash(git push --force:*)', 'Bash(git push -f:*)', 'Bash(rm -rf /:*)', 'Bash(rm -rf ~:*)',
    'Bash(sudo:*)', 'Bash(git reset --hard origin:*)',
  ],
  // Modelo por fase (null = el predeterminado de tu Claude Code).
  models: { plan: null, validate: null, build: null, test: null, deploy: null },
  // Se añaden desde la app (arrastrando carpetas del Finder) o editando este archivo:
  // { id, name, path, baseBranch, testCmd, deployCmd, autoDeploy, scanPaths }
  projects: [],
};

export function ensureDirs() {
  for (const d of [HOME, PATHS.tasks, PATHS.worktrees]) fs.mkdirSync(d, { recursive: true });
}

export function loadConfig() {
  ensureDirs();
  if (!fs.existsSync(PATHS.config)) {
    fs.writeFileSync(PATHS.config, JSON.stringify(DEFAULTS, null, 2));
    return structuredClone(DEFAULTS);
  }
  const user = JSON.parse(fs.readFileSync(PATHS.config, 'utf8'));
  return { ...structuredClone(DEFAULTS), ...user, models: { ...DEFAULTS.models, ...user.models } };
}
