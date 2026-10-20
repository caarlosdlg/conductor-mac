import fs from 'node:fs';
import path from 'node:path';
import { runClaude } from './worker.js';
import { PATHS } from './config.js';

/**
 * Capa de administración. Toda decisión que cruza un límite pasa por `admin.review()`.
 *
 *   review(ctx, task, project, gate) -> { decision, reason, guidance? }
 *   gate.type: 'deploy' | 'blocked' | 'failed'
 *   decision:  'approve' | 'ask' (escalar al humano) | 'reject' | 'guide' (reintentar con indicación)
 *
 * Reglas duras primero (deployCmd, autoDeploy); el agente sólo opina dentro de ellas
 * y nunca puede aprobar lo que las reglas niegan.
 */
const ADMIN_TOOLS = ['Read', 'Glob', 'Grep', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git status:*)', 'Bash(git show:*)'];

function extractJson(text) {
  const m = /\{[\s\S]*\}/.exec(text || '');
  if (!m) return null;
  try { return JSON.parse(m[0]); } catch { return null; }
}

async function ask(ctx, task, prompt) {
  const dir = path.join(PATHS.tasks, task.id);
  const out = await runClaude({
    prompt, cwd: task.workspace || ctx.cfg.projects.find((p) => p.id === task.project)?.path,
    taskId: task.id, bin: ctx.cfg.claudeBin, model: ctx.cfg.adminModel || undefined,
    mode: 'default', addDirs: [dir], allowedTools: ADMIN_TOOLS, disallowedTools: [], onEvent: () => {},
  });
  task.cost += out.cost;
  return extractJson(out.result);
}

const tail = (task, n = 25) => task.log.slice(-n).join('\n');
const FORMAT = 'Responde SOLO con un JSON en una línea, sin texto extra.';

export const admin = {
  async review(ctx, task, project, gate) {
    const useAgent = ctx.cfg.adminAgent;

    if (gate.type === 'deploy') {
      if (!project.deployCmd) return { decision: 'reject', reason: 'sin deployCmd configurado: la rama queda lista para revisión' };
      if (!project.autoDeploy) return { decision: 'ask', reason: 'despliegue requiere tu aprobación (autoDeploy desactivado)' };
      if (!useAgent) return { decision: 'approve', reason: 'autoDeploy activo' };
      const j = await ask(ctx, task, `Eres el administrador de despliegues. Revisa el trabajo de la tarea "${task.title}" en la rama ${task.branch || 'actual'} (git diff contra ${task.baseBranch || 'la base'}). ` +
        `Busca: secretos o credenciales en el diff, migraciones destructivas, cambios fuera de alcance, pruebas ausentes. ${FORMAT} ` +
        `Formato: {"decision":"approve"|"ask","reason":"..."}  (usa "ask" ante cualquier duda real; el despliegue es: ${project.deployCmd})`);
      if (j?.decision === 'approve') return { decision: 'approve', reason: j.reason || 'revisado por admin' };
      return { decision: 'ask', reason: j?.reason || 'el admin no pudo validar el deploy' };
    }

    // blocked | failed
    if (!useAgent || (task.adminInterventions || 0) >= ctx.cfg.maxAdminInterventions) {
      return { decision: 'ask', reason: gate.note || gate.type };
    }
    const plan = (() => { try { return fs.readFileSync(path.join(PATHS.tasks, task.id, 'PLAN.md'), 'utf8').slice(0, 4000); } catch { return ''; } })();
    const j = await ask(ctx, task, `Eres el administrador de un equipo de agentes de ingeniería. Una tarea quedó ${gate.type === 'blocked' ? 'BLOQUEADA' : 'FALLIDA'} en la fase "${task.phase}".\n` +
      `TAREA: ${task.title}\nMOTIVO: ${gate.note}\nÚLTIMO LOG:\n${tail(task)}\nPLAN:\n${plan}\n\n` +
      `Tu objetivo es que la tarea AVANCE sin molestar al humano. Si el bloqueo es una ambigüedad de producto, diseño, copy, alcance o convención, DECIDE tú la opción más razonable y conservadora ` +
      `e indica al agente que la registre bajo "## Supuestos" en PLAN.md para que el humano la revise al final. Si es un fallo técnico, da la instrucción concreta para resolverlo o un enfoque alternativo. ` +
      `Escala ("ask") ÚNICAMENTE si es imposible continuar sin: credenciales/secretos/accesos que no existen, un pago, o una acción destructiva o irreversible (borrar datos, force-push, tocar producción), o si el mismo fallo ya se repitió sin progreso. ${FORMAT} ` +
      `Formato: {"decision":"guide"|"ask","guidance":"instrucción concreta y accionable para reintentar","reason":"..."}`);
    if (j?.decision === 'guide' && j.guidance) {
      return { decision: 'guide', guidance: String(j.guidance).slice(0, 1500), reason: j.reason || 'indicación del admin' };
    }
    return { decision: 'ask', reason: j?.reason || gate.note || gate.type };
  },
};
