import { spawn } from 'node:child_process';

const summarizeTool = (b) => {
  const i = b.input || {};
  const target = i.file_path || i.command || i.pattern || i.path || i.url || i.description || '';
  return `⚙ ${b.name} ${String(target).replace(/\s+/g, ' ').slice(0, 90)}`;
};

/**
 * Ejecuta una sesión headless de Claude Code y emite eventos de progreso.
 * El contexto se calcula con el `usage` del último mensaje del agente principal
 * (input + cache_creation + cache_read), que es lo que ocupa la ventana.
 * Si supera `ctxLimitTokens` se mata el proceso y se devuelve { rotate: true }.
 */
export function runClaude(o) {
  return new Promise((resolve) => {
    const args = ['-p', o.prompt, '--output-format', 'stream-json', '--verbose', '--permission-mode', o.mode];
    if (o.resume) args.push('--resume', o.resume);
    if (o.model) args.push('--model', o.model);
    for (const d of o.addDirs || []) args.push('--add-dir', d);
    if (o.allowedTools?.length) args.push('--allowedTools', o.allowedTools.join(','));
    if (o.disallowedTools?.length) args.push('--disallowedTools', o.disallowedTools.join(','));

    const child = spawn(o.bin || 'claude', args, {
      cwd: o.cwd,
      env: { ...process.env, CONDUCTOR_TASK: o.taskId || '' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    o.onSpawn?.(child);

    const out = { sessionId: o.resume || null, result: '', isError: false, cost: 0, rotate: false, code: null, stderr: '', ctxTokens: 0 };
    let buf = '';

    const handle = (ev) => {
      if (ev.session_id) out.sessionId = ev.session_id;
      if (ev.type === 'system' && ev.subtype === 'init') o.onEvent?.({ kind: 'init', sessionId: ev.session_id, model: ev.model });
      else if (ev.type === 'assistant' && !ev.parent_tool_use_id) {
        const u = ev.message?.usage;
        if (u) {
          out.ctxTokens = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
          o.onEvent?.({ kind: 'ctx', tokens: out.ctxTokens });
          if (o.ctxLimitTokens && out.ctxTokens >= o.ctxLimitTokens && !out.rotate) {
            out.rotate = true;
            child.kill('SIGTERM');
          }
        }
        for (const b of ev.message?.content || []) {
          if (b.type === 'text' && b.text.trim()) o.onEvent?.({ kind: 'text', text: b.text.trim() });
          else if (b.type === 'tool_use') o.onEvent?.({ kind: 'tool', text: summarizeTool(b) });
        }
      } else if (ev.type === 'rate_limit_event' && ev.rate_limit_info) {
        o.onEvent?.({ kind: 'rate', info: ev.rate_limit_info });
      } else if (ev.type === 'result') {
        out.result = ev.result || '';
        out.isError = !!ev.is_error;
        out.cost = ev.total_cost_usd || 0;
      }
    };

    child.stdout.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        try { handle(JSON.parse(line)); } catch {}
      }
    });
    child.stderr.on('data', (d) => { out.stderr = (out.stderr + d).slice(-2000); });
    child.on('error', (e) => { out.stderr += String(e); out.isError = true; resolve(out); });
    child.on('close', (code, sig) => { out.code = code; out.killed = sig != null; resolve(out); });
  });
}

/** Extrae la línea de protocolo `PHASE_RESULT: OK|BLOCKED|FAILED motivo`. */
export function parsePhaseResult(text) {
  const m = /PHASE_RESULT:\s*(OK|BLOCKED|FAILED)\s*(.*)/i.exec(text || '');
  return m ? { status: m[1].toUpperCase(), note: (m[2] || '').trim() } : null;
}
