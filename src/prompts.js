export const PHASES = ['plan', 'validate', 'build', 'test', 'deploy'];
export const PHASE_LABEL = { plan: 'Planear', validate: 'Validar', build: 'Construir', test: 'Probar', deploy: 'Desplegar' };

const PROTOCOL = `
PROTOCOLO (obligatorio): termina tu ÚLTIMO mensaje con exactamente una línea:
PHASE_RESULT: OK <resumen breve>        -> la fase se cumplió
PHASE_RESULT: BLOCKED <qué necesitas>   -> sólo si necesitas una decisión/dato humano que no puedes inferir
PHASE_RESULT: FAILED <motivo>           -> no se pudo completar tras intentarlo con seriedad
Toma tú las mejores decisiones técnicas; no hagas preguntas que puedas resolver leyendo el código.`;

export function buildPrompt(task, project, phase, ctx) {
  const { dir, cwd, branch, guidance, handoffExists, testCmd } = ctx;
  const head = `Eres un ingeniero senior trabajando de forma autónoma dentro de un orquestador.
PROYECTO: ${project.name} (${cwd})
TAREA [${task.id}]: ${task.title}
${task.desc ? `DETALLE: ${task.desc}\n` : ''}Carpeta de trabajo de la tarea (fuera del repo): ${dir}
  - PLAN.md     plan vigente
  - HANDOFF.md  estado para continuar si tu contexto se agota
${branch ? `Rama de trabajo: ${branch} (ya estás en su worktree).` : 'Trabajas directamente en el repo.'}
${guidance ? `\nINDICACIÓN DEL HUMANO/ADMIN (prioridad alta): ${guidance}\n` : ''}${
  handoffExists ? `\nSI HAY CONTINUACIÓN: lee ${dir}/HANDOFF.md primero y revisa \`git status\` / \`git diff --stat\`; retoma exactamente donde quedó, no repitas trabajo.\n` : ''}`;

  const body = {
    plan: `FASE: PLANEAR.
1. Explora el código relevante y las convenciones del proyecto (CLAUDE.md, README, tests existentes).
2. Escribe ${dir}/PLAN.md con: objetivo, enfoque elegido y alternativas descartadas (con motivo), pasos ordenados, archivos a tocar, riesgos, criterios de aceptación VERIFICABLES y los comandos exactos para probarlos${testCmd ? ` (comando de pruebas del proyecto: ${testCmd})` : ''}.
3. NO modifiques archivos del proyecto en esta fase.`,
    validate: `FASE: VALIDAR EL PLAN (revisor crítico independiente).
Lee ${dir}/PLAN.md y contrástalo con el código real: ¿los archivos/funciones existen?, ¿el enfoque es el más simple que cumple?, ¿faltan casos borde, seguridad, migraciones, tests?, ¿los criterios son verificables?
Corrige PLAN.md directamente. Responde OK sólo si el plan resultante es ejecutable sin ambigüedad. NO modifiques código del proyecto.`,
    build: `FASE: CONSTRUIR.
Implementa ${dir}/PLAN.md. Commits pequeños y descriptivos${branch ? ` en la rama ${branch}` : ''}. Respeta el estilo existente; no refactorices fuera de alcance.
Tras cada hito relevante actualiza ${dir}/HANDOFF.md (hecho / pendiente / decisiones / archivos tocados / siguiente paso exacto): tu contexto puede cortarse en cualquier momento y otra sesión continuará desde ahí.
Escribe o actualiza los tests que cubran los criterios de aceptación.`,
    test: `FASE: PROBAR.
Ejecuta typecheck, lint, tests y build del proyecto${testCmd ? ` (usa: ${testCmd})` : ''}, y verifica cada criterio de aceptación de ${dir}/PLAN.md. Si algo falla, corrígelo y repite hasta que todo pase.
Si es una UI y es viable, levanta el servidor de desarrollo y compruébalo. Si tras varios intentos honestos sigue fallando, termina con FAILED y el diagnóstico exacto (comando, error, hipótesis).`,
    deploy: `FASE: DESPLEGAR.
${branch ? `1. Verifica que la rama ${branch} está limpia y las pruebas pasan; intégrala a ${task.baseBranch || project.baseBranch || 'main'} ejecutando en el repo principal: git -C ${project.path} merge --ff-only ${branch} (esa rama está desplegada ahí, no se puede abrir en este worktree; si el repo principal tiene cambios sin commitear que choquen, NO los toques: reporta BLOCKED; sin force-push).\n` : '1. Verifica que el árbol está limpio y las pruebas pasan.\n'}2. Ejecuta el despliegue con: ${project.deployCmd}
3. Verifica que quedó arriba (salida del comando / URL / health check) y reporta la URL o identificador del despliegue.
Si algo falla, NO improvises un rollback destructivo: detente y repórtalo con FAILED.`,
  }[phase];

  return `${head}\n${body}\n${PROTOCOL}`;
}

export const handoffPrompt = (dir) =>
  `Tu ventana de contexto está por agotarse y otra sesión continuará tu trabajo. NO avances más en la tarea. ` +
  `Escribe/actualiza ${dir}/HANDOFF.md con: 1) qué está hecho, 2) qué falta, 3) decisiones y por qué, 4) archivos tocados, 5) siguiente paso exacto, 6) comandos útiles/errores conocidos. Sé concreto. Termina con: PHASE_RESULT: OK handoff`;
