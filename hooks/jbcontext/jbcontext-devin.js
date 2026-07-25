#!/usr/bin/env node
// jbcontext — Devin CLI adapter for JetBrains Context hooks.
//
// Translates Devin tool names/events into the Claude-shaped schema expected by
// `jbcontext hook`, then translates the Claude-shaped response back into Devin
// hook output. Supports REMIND and ENFORCE/ENFORCE_SOFT via JBCONTEXT_HOOK_MODE.
// ENFORCE_SOFT is the default: it uses the ENFORCE state machine but rewrites
// blocked tools to no-ops instead of cancelling the agent cycle.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

function findJbcontextBinary() {
  if (process.env.JBCONTEXT_BINARY) return process.env.JBCONTEXT_BINARY;
  const candidates = [
    '/Users/warelik/.jbcontext/bin/jbcontext',
    '/usr/local/bin/jbcontext',
    '/opt/homebrew/bin/jbcontext',
    path.join(os.homedir(), '.jbcontext', 'bin', 'jbcontext'),
    path.join(os.homedir(), '.local', 'bin', 'jbcontext'),
  ];
  for (const p of candidates) {
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (e) {}
  }
  const fromWhich = spawnSync('which', ['jbcontext'], { encoding: 'utf8' }).stdout?.trim();
  if (fromWhich) return fromWhich;
  return 'jbcontext';
}

const JBCONTEXT = findJbcontextBinary();
const MODE = (process.env.JBCONTEXT_HOOK_MODE || 'ENFORCE_SOFT').toUpperCase();
const EVENT = process.argv[2] || '';

const DISCOVERY_RE = /(?:^|\s)(?:rg|grep|find)(?:\s|$)/;
const GIT_HISTORY_RE = /(?:^|\s)git\s+(?:log|show|blame)(?:\s|$)/;

function readStdin() {
  return new Promise((resolve) => {
    let input = '';
    let done = false;
    function finish() {
      if (done) return;
      done = true;
      resolve(input);
    }
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', finish);
    process.stdin.on('error', finish);
    setTimeout(finish, 3000).unref();
  });
}

function projectPath() {
  return process.env.DEVIN_PROJECT_DIR || process.cwd();
}

// Fail-open backend health. Suppressing local discovery (grep/glob/find) is only
// justified when a semantic-search backend can actually serve this project. If the
// jbcontext search backend is unreachable or the project has no usable index, we
// must NOT suppress — otherwise the agent is left with no way to search (the exact
// deadlock this guard prevents). Probe once per session, cache the verdict.
function sessionKey(payload) {
  return String((payload && (payload.session_id || payload.prompt_id)) || 'default')
    .replace(/[^A-Za-z0-9._-]/g, '_')
    .slice(0, 80);
}

function backendHealthy(payload) {
  if (process.env.JBCONTEXT_ASSUME_BACKEND === '1') return true;
  if (process.env.JBCONTEXT_ASSUME_BACKEND === '0') return false;
  const dir = path.join(os.homedir(), '.jbcontext', 'hooks');
  const cacheFile = path.join(dir, `backend-${sessionKey(payload)}.json`);
  try {
    const c = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
    if (Date.now() - c.t < 300000) return c.ok;
  } catch (e) { /* no fresh cache */ }
  let ok = false;
  try {
    const res = spawnSync(
      JBCONTEXT,
      ['search', '--project-path', projectPath(), '--json-output', 'jbcontext backend health probe'],
      { encoding: 'utf8', timeout: 8000, maxBuffer: 1024 * 1024 }
    );
    const out = `${res.stdout || ''}${res.stderr || ''}`;
    ok = !res.error && res.status === 0 && !/no repositories available|not indexed|no index|please open a project/i.test(out);
  } catch (e) { ok = false; }
  try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(cacheFile, JSON.stringify({ ok, t: Date.now() })); } catch (e) { /* best-effort */ }
  return ok;
}

function runIndex() {
  const child = spawn(
    JBCONTEXT,
    ['index', '--silent', '--project-path', projectPath()],
    { stdio: 'ignore', detached: true }
  );
  child.on('error', (err) => {
    console.error('jbcontext-devin: failed to start index:', err.message);
  });
  child.unref();
}

const SESSION_START_FILE = path.join(__dirname, 'session-start.txt');
const FALLBACK_SESSION_START_CONTEXT = `Use JetBrains Context for semantic code search. Start with one broad jbcontext search or mcp__jbcontext__code_search, read at least one returned file, inspect nearby code locally, and only then narrow with jbcontext search -p <path> or pathFilter. Do not start with grep/ripgrep/find or git history when the location is unknown.`;

function sessionStartContext() {
  try {
    const text = fs.readFileSync(SESSION_START_FILE, 'utf8');
    return text.trim() || FALLBACK_SESSION_START_CONTEXT;
  } catch (e) {
    return FALLBACK_SESSION_START_CONTEXT;
  }
}

function writeSessionContext(event, context) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: event,
      additionalContext: context,
    },
  }));
}

function toJbcontextEvent(event) {
  switch (event) {
    case 'PreToolUse': return 'pre-tool-use';
    case 'PostToolUse': return 'post-tool-use';
    case 'UserPromptSubmit': return 'user-prompt-submit';
    default: return event.toLowerCase();
  }
}

function jbcontextMode() {
  if (MODE === 'ENFORCE_SOFT' || MODE === 'ENFORCE_NOBATCH') return 'ENFORCE';
  return MODE;
}

function callJbcontextHook(event, payload) {
  const jbEvent = toJbcontextEvent(event);
  const result = spawnSync(
    JBCONTEXT,
    ['hook', jbEvent, '--agent', 'CLAUDE', '--mode', jbcontextMode()],
    {
      input: JSON.stringify(payload),
      encoding: 'utf8',
      timeout: 15000,
      maxBuffer: 1024 * 1024,
    }
  );
  if (result.error) {
    console.error('jbcontext-devin: jbcontext hook failed:', result.error.message);
    return null;
  }
  if (result.stderr && result.stderr.trim()) {
    console.error('jbcontext-devin: jbcontext stderr:', result.stderr.trim());
  }
  return result.stdout;
}

function mapToolName(devinName) {
  switch (devinName) {
    case 'exec': return 'Bash';
    case 'read': return 'Read';
    case 'grep': return 'Grep';
    case 'glob': return 'Glob';
    default: return devinName;
  }
}

function shellQuote(str) {
  return JSON.stringify(String(str));
}

function buildSyntheticSearchCommand(toolInput) {
  const text = String(toolInput.text || toolInput.query || '');
  const pathFilter = toolInput.pathFilter || toolInput.path_filter || '';
  const query = shellQuote(text);
  if (pathFilter) {
    return `jbcontext search -p ${shellQuote(pathFilter)} ${query}`;
  }
  return `jbcontext search ${query}`;
}

function unwrapRtk(command) {
  // RTK is a Devin command wrapper. Expose the underlying command to jbcontext
  // so it can enforce the same discovery rules (e.g. `rtk find` -> `find`).
  return String(command).replace(/^rtk\s+/, '');
}

function toClaudePayload(devinPayload) {
  const toolName = devinPayload.tool_name;
  const toolInput = devinPayload.tool_input || {};
  const claude = { ...devinPayload };

  if (toolName === 'mcp__jbcontext__code_search') {
    claude.tool_name = 'Bash';
    claude.tool_input = { command: buildSyntheticSearchCommand(toolInput) };
  } else if (toolName === 'exec') {
    claude.tool_name = 'Bash';
    claude.tool_input = { command: unwrapRtk(toolInput.command) };
  } else {
    claude.tool_name = mapToolName(toolName);
  }

  return claude;
}

function isSoftEnforce() {
  return MODE === 'ENFORCE_SOFT' || MODE === 'ENFORCE_NOBATCH';
}

function buildSoftDenyOutput(payload, reason) {
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};
  const message = `[jbcontext ${MODE}] ${reason} Use one broad jbcontext search first, read a result, then retry local discovery.`;
  let updatedInput = null;

  if (toolName === 'exec') {
    updatedInput = { command: `printf '%s\\n' ${JSON.stringify(message)}` };
  } else if (toolName === 'grep') {
    updatedInput = { ...toolInput, pattern: '__JBCONTEXT_SUPPRESSED__', output_mode: 'content', max_results: 0 };
  } else if (toolName === 'glob') {
    updatedInput = { ...toolInput, pattern: '__JBCONTEXT_SUPPRESSED__' };
  } else if (toolName === 'mcp__jbcontext__code_search') {
    updatedInput = { text: '__JBCONTEXT_SUPPRESSED__' };
  }

  if (!updatedInput) {
    return JSON.stringify({ decision: 'block', reason });
  }

  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      updatedInput,
      additionalContext: message
    }
  });
}

function translateOutput(stdout, eventName, payload) {
  stdout = (stdout || '').trim();
  if (!stdout) return null;
  try {
    const parsed = JSON.parse(stdout);
    const hso = parsed.hookSpecificOutput || {};
    if (hso.permissionDecision === 'deny') {
      const reason = hso.permissionDecisionReason || 'Blocked by JetBrains Context ENFORCE workflow.';
      // Fail-open: never suppress/block when no semantic backend can serve this
      // project. Relax to a tip so direct discovery still works, instead of
      // leaving the agent with no search path (deadlock guard).
      if (!backendHealthy(payload)) {
        return JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            additionalContext: `[jbcontext ${MODE}] semantic backend unavailable — enforcement relaxed, using direct search. ${reason}`
          }
        });
      }
      if (isSoftEnforce()) {
        return buildSoftDenyOutput(payload, reason);
      }
      return JSON.stringify({ decision: 'block', reason });
    }
    if (hso.additionalContext) {
      return JSON.stringify({
        hookSpecificOutput: {
          hookEventName: hso.hookEventName || eventName,
          additionalContext: hso.additionalContext
        }
      });
    }
    return null;
  } catch (e) {
    console.error('jbcontext-devin: failed to parse jbcontext output:', stdout);
    return null;
  }
}

function toolSucceeded(toolResponse) {
  if (!toolResponse) return true;
  return toolResponse.success !== false;
}

function shouldCallPreToolUse(payload) {
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};

  if (toolName === 'mcp__jbcontext__code_search') return true;
  if (toolName === 'grep' || toolName === 'glob') return true;
  if (toolName === 'exec') {
    const cmd = String(toolInput.command || '');
    if (cmd.includes('jbcontext search')) return true;
    if (DISCOVERY_RE.test(cmd)) return true;
    if (GIT_HISTORY_RE.test(cmd)) return true;
    return false;
  }
  return false;
}

function shouldCallPostToolUse(payload) {
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};

  if (!toolSucceeded(payload.tool_response)) return false;

  if (toolName === 'read') return true;
  if (toolName === 'mcp__jbcontext__code_search') return true;
  if (toolName === 'exec') {
    const cmd = String(toolInput.command || '');
    return cmd.includes('jbcontext search');
  }
  return false;
}

function isNoopToolInput(toolName, toolInput) {
  if (toolName === 'mcp__jbcontext__code_search') {
    return String(toolInput.text || '').startsWith('__JBCONTEXT_SUPPRESSED__');
  }
  if (toolName === 'grep' || toolName === 'glob') {
    return String(toolInput.pattern || '') === '__JBCONTEXT_SUPPRESSED__';
  }
  return false;
}

function readJbcontextState(sessionId) {
  if (!sessionId) return {};
  const file = path.join(os.homedir(), '.jbcontext', 'hooks', `state-${sessionId}.json`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    return {};
  }
}

// The jbcontext MCP code_search tool currently returns no results when pathFilter
// is omitted (the server fails to resolve the project root). Inject pathFilter: '.'
// only for the first broad semantic search (bootstrap not yet done), so the MCP
// call returns snippets without turning later broad retries into allowed project-wide
// searches.
function normalizeMcpCodeSearchInput(toolInput, sessionId) {
  if (!toolInput) return false;
  if (String(toolInput.text || '').startsWith('__JBCONTEXT_SUPPRESSED__')) return false;
  if (toolInput.pathFilter || toolInput.path_filter) return false;
  const state = readJbcontextState(sessionId);
  if (state.bootstrap_done) return false;
  toolInput.pathFilter = '.';
  return true;
}

function finalizePreToolUseOutput(output, payload, injectedPathFilter) {
  if (!injectedPathFilter || payload.tool_name !== 'mcp__jbcontext__code_search') {
    return output;
  }
  let parsed = {};
  if (output) {
    try { parsed = JSON.parse(output); } catch (e) { parsed = {}; }
  }
  // Do not rewrite hard blocks or existing soft-deny no-ops.
  if (parsed.decision === 'block') return output;
  const hso = parsed.hookSpecificOutput || {};
  if (hso.updatedInput) return output;
  hso.hookEventName = hso.hookEventName || 'PreToolUse';
  hso.updatedInput = payload.tool_input;
  parsed.hookSpecificOutput = hso;
  return JSON.stringify(parsed);
}

async function handleToolEvent(event, raw) {
  let payload = {};
  try {
    payload = JSON.parse(raw.replace(/^\uFEFF/, ''));
  } catch (e) {
    console.error('jbcontext-devin: invalid JSON on stdin:', e.message);
    return;
  }

  if (event === 'PreToolUse' && !shouldCallPreToolUse(payload)) return;
  if (event === 'PostToolUse' && !shouldCallPostToolUse(payload)) return;

  if (event === 'PostToolUse' && isNoopToolInput(payload.tool_name, payload.tool_input || {})) {
    // No-op was injected in PreToolUse; do not update jbcontext state.
    return;
  }

  const injectedPathFilter = payload.tool_name === 'mcp__jbcontext__code_search'
    && normalizeMcpCodeSearchInput(payload.tool_input || {}, payload.session_id);

  const claudePayload = toClaudePayload(payload);
  const stdout = callJbcontextHook(event, claudePayload);
  let output = translateOutput(stdout, event, payload);

  if (injectedPathFilter && event === 'PreToolUse') {
    output = finalizePreToolUseOutput(output, payload, injectedPathFilter);
  }

  if (output) {
    process.stdout.write(output);
    if (!isSoftEnforce() && output.includes('"decision":"block"')) {
      process.exit(2);
    }
  }
}

async function handlePromptEvent(event, raw) {
  let payload = {};
  try {
    payload = JSON.parse(raw.replace(/^\uFEFF/, ''));
  } catch (e) {
    console.error('jbcontext-devin: invalid JSON on stdin:', e.message);
    return;
  }

  const stdout = callJbcontextHook(event, payload);
  const output = translateOutput(stdout, event);
  if (output) process.stdout.write(output);
}

async function main() {
  const event = EVENT;
  if (!event) {
    console.error('jbcontext-devin: no event argument');
    return;
  }

  if (event === 'SessionStart') {
    writeSessionContext(event, sessionStartContext());
    runIndex();
    return;
  }

  if (event === 'SessionEnd') {
    runIndex();
    return;
  }

  if (event === 'PostCompaction') {
    writeSessionContext(event, sessionStartContext());
    return;
  }

  const raw = await readStdin();

  if (event === 'UserPromptSubmit') {
    return handlePromptEvent(event, raw);
  }

  if (event === 'PreToolUse' || event === 'PostToolUse') {
    return handleToolEvent(event, raw);
  }
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------

function cleanTestState(prefix) {
  const hooksDir = path.join(os.homedir(), '.jbcontext', 'hooks');
  if (!fs.existsSync(hooksDir)) return;
  for (const entry of fs.readdirSync(hooksDir)) {
    if (entry.startsWith('state-' + prefix) || entry.startsWith('reminders-' + prefix)) {
      try { fs.unlinkSync(path.join(hooksDir, entry)); } catch (e) {}
    }
  }
}

function invoke(event, payload, mode, extraEnv) {
  return spawnSync(process.execPath, [__filename, event], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    timeout: 20000,
    env: {
      ...process.env,
      JBCONTEXT_HOOK_MODE: mode || 'ENFORCE_SOFT',
      // Existing suppression cases assume a working backend; fail-open cases pass '0'.
      JBCONTEXT_ASSUME_BACKEND: (extraEnv && extraEnv.JBCONTEXT_ASSUME_BACKEND) || '1'
    }
  });
}

function selfTest() {
  const prefix = 'jbcontext_devin_selftest';
  cleanTestState(prefix);

  const results = [];
  const check = (label, fn) => {
    try {
      fn();
      results.push({ label, ok: true });
      console.error(`[PASS] ${label}`);
    } catch (e) {
      results.push({ label, ok: false, error: e.message });
      console.error(`[FAIL] ${label}: ${e.message}`);
    }
  };

  const session = (s) => `${prefix}_${s}`;

  check('ENFORCE PreToolUse exec rg blocked before bootstrap', () => {
    const res = invoke('PreToolUse', {
      session_id: session('a'),
      tool_name: 'exec',
      tool_input: { command: 'rg auth src' }
    }, 'ENFORCE');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision !== 'block') throw new Error(`expected block, got: ${res.stdout}`);
    if (!out.reason) throw new Error('missing reason');
  });

  check('ENFORCE PreToolUse exec git log blocked before bootstrap', () => {
    const res = invoke('PreToolUse', {
      session_id: session('a2'),
      tool_name: 'exec',
      tool_input: { command: 'git log --oneline src' }
    }, 'ENFORCE');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision !== 'block') throw new Error(`expected block, got: ${res.stdout}`);
    if (!out.reason.includes('git history')) throw new Error(`wrong reason: ${res.stdout}`);
  });

  check('ENFORCE PreToolUse exec find blocked before bootstrap', () => {
    const res = invoke('PreToolUse', {
      session_id: session('a3'),
      tool_name: 'exec',
      tool_input: { command: 'find . -name "*.kt"' }
    }, 'ENFORCE');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision !== 'block') throw new Error(`expected block, got: ${res.stdout}`);
  });

  check('PreToolUse exec ls allowed before bootstrap', () => {
    const res = invoke('PreToolUse', {
      session_id: session('b'),
      tool_name: 'exec',
      tool_input: { command: 'ls -la' }
    });
    if (res.stdout.trim()) throw new Error(`unexpected output: ${res.stdout}`);
  });

  check('PreToolUse grep no-ops by default (ENFORCE_SOFT)', () => {
    const res = invoke('PreToolUse', {
      session_id: session('c'),
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src', output_mode: 'files_with_matches', max_results: 30 }
    });
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision) throw new Error(`default blocked instead of no-op: ${res.stdout}`);
    if (out.hookSpecificOutput?.updatedInput?.pattern !== '__JBCONTEXT_SUPPRESSED__') {
      throw new Error(`default did not no-op grep: ${res.stdout}`);
    }
    if (out.hookSpecificOutput?.updatedInput?.output_mode !== 'content') {
      throw new Error(`default did not switch grep output_mode: ${res.stdout}`);
    }
  });

  check('PreToolUse mcp code_search allowed first time', () => {
    const res = invoke('PreToolUse', {
      session_id: session('d'),
      tool_name: 'mcp__jbcontext__code_search',
      tool_input: { text: 'how auth works' }
    });
    const out = res.stdout.trim();
    if (out.includes('block')) throw new Error(`first search blocked: ${out}`);
  });

  check('PostToolUse mcp code_search updates bootstrap state', () => {
    const sid = session('d');
    invoke('PostToolUse', {
      session_id: sid,
      tool_name: 'mcp__jbcontext__code_search',
      tool_input: { text: 'how auth works' },
      tool_response: { success: true, output: '...', error: null }
    });
    const res = invoke('PreToolUse', {
      session_id: sid,
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src' }
    });
    const out = res.stdout.trim();
    if (out.includes('read') && out.includes('bootstrap')) return; // still needs read
    // If it was allowed, we are still okay as long as not the original deny.
    if (out.includes('Do not start broad local discovery')) {
      throw new Error('bootstrap state not updated: ' + out);
    }
  });

  check('PreToolUse mcp code_search second broad returns sentinel by default', () => {
    const sid = session('e');
    invoke('PostToolUse', {
      session_id: sid,
      tool_name: 'mcp__jbcontext__code_search',
      tool_input: { text: 'first search' },
      tool_response: { success: true, output: '...', error: null }
    });
    invoke('PostToolUse', {
      session_id: sid,
      tool_name: 'read',
      tool_input: { file_path: 'x' },
      tool_response: { success: true, output: '...', error: null }
    });
    const res = invoke('PreToolUse', {
      session_id: sid,
      tool_name: 'mcp__jbcontext__code_search',
      tool_input: { text: 'second broad search' }
    });
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision) throw new Error(`second broad blocked instead of sentinel: ${res.stdout}`);
    if (out.hookSpecificOutput?.updatedInput?.text !== '__JBCONTEXT_SUPPRESSED__') {
      throw new Error(`second broad not no-opped: ${res.stdout}`);
    }
  });

  check('UserPromptSubmit injects workflow context', () => {
    const res = invoke('UserPromptSubmit', {
      session_id: session('f'),
      prompt: 'how does auth work'
    });
    const out = JSON.parse(res.stdout || '{}');
    if (!out.hookSpecificOutput || !out.hookSpecificOutput.additionalContext) {
      throw new Error(`missing context: ${res.stdout}`);
    }
    if (out.hookSpecificOutput.hookEventName !== 'UserPromptSubmit') {
      throw new Error(`wrong event: ${res.stdout}`);
    }
  });

  check('REMIND PreToolUse grep returns tip, not block', () => {
    const res = invoke('PreToolUse', {
      session_id: session('g'),
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src' }
    }, 'REMIND');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision) throw new Error(`REMIND blocked: ${res.stdout}`);
    if (!out.hookSpecificOutput || !out.hookSpecificOutput.additionalContext) {
      throw new Error(`REMIND missing tip: ${res.stdout}`);
    }
  });

  check('mcp code_search with pathFilter maps to narrowed command', () => {
    const res = invoke('PreToolUse', {
      session_id: session('h'),
      tool_name: 'mcp__jbcontext__code_search',
      tool_input: { text: 'auth', pathFilter: 'src/auth' }
    });
    // First narrowed search is allowed.
    const out = res.stdout.trim();
    if (out.includes('block')) throw new Error(`narrowed first search blocked: ${out}`);
  });

  check('ENFORCE PreToolUse grep hard blocks', () => {
    const res = invoke('PreToolUse', {
      session_id: session('i'),
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src' }
    }, 'ENFORCE');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision !== 'block') throw new Error(`ENFORCE did not block: ${res.stdout}`);
  });

  check('ENFORCE_SOFT PreToolUse exec rg no-ops with message', () => {
    const res = invoke('PreToolUse', {
      session_id: session('j'),
      tool_name: 'exec',
      tool_input: { command: 'rg auth src' }
    }, 'ENFORCE_SOFT');
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision) throw new Error(`ENFORCE_SOFT blocked instead of no-op: ${res.stdout}`);
    if (!out.hookSpecificOutput?.updatedInput?.command?.includes('printf')) {
      throw new Error(`ENFORCE_SOFT did not no-op exec: ${res.stdout}`);
    }
  });

  check('FAIL-OPEN (SOFT): backend down → grep NOT suppressed, relaxed to tip', () => {
    const res = invoke('PreToolUse', {
      session_id: session('failopen_soft'),
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src' }
    }, 'ENFORCE_SOFT', { JBCONTEXT_ASSUME_BACKEND: '0' });
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision) throw new Error(`fail-open blocked: ${res.stdout}`);
    if (out.hookSpecificOutput?.updatedInput) throw new Error(`fail-open still suppressed grep: ${res.stdout}`);
    if (!out.hookSpecificOutput?.additionalContext?.includes('backend unavailable')) {
      throw new Error(`fail-open missing relax tip: ${res.stdout}`);
    }
  });

  check('FAIL-OPEN (ENFORCE): backend down → grep NOT hard-blocked', () => {
    const res = invoke('PreToolUse', {
      session_id: session('failopen_hard'),
      tool_name: 'grep',
      tool_input: { pattern: 'auth', path: 'src' }
    }, 'ENFORCE', { JBCONTEXT_ASSUME_BACKEND: '0' });
    const out = JSON.parse(res.stdout || '{}');
    if (out.decision === 'block') throw new Error(`fail-open hard still blocked: ${res.stdout}`);
  });

  const failed = results.filter(r => !r.ok);
  if (failed.length) {
    console.error(`[SELF-TEST] ${failed.length}/${results.length} failed`);
    process.exit(1);
  }
  console.error(`[SELF-TEST] ${results.length}/${results.length} passed`);
}

if (EVENT === '--self-test') {
  selfTest();
} else {
  main().catch((e) => {
    console.error('jbcontext-devin:', e.message || e);
  });
}
