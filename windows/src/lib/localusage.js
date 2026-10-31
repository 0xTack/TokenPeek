'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const { execFile, execFileSync } = require('child_process');
const { promisify } = require('util');
const paths = require('./paths');

const execFileAsync = promisify(execFile);

const APP_LABELS = {
  claude: 'Claude Code',
  'claude-desktop': 'Claude Desktop',
  codex: 'Codex',
  gemini: 'Gemini CLI',
  grokbuild: 'Grok',
  openclaw: 'OpenClaw',
  hermes: 'Hermes',
  pi: 'Pi',
  local: '本地接口',
};

const LOCAL_APP_IDS = new Set(Object.keys(APP_LABELS));

const DB_SQL = `
SELECT request_id AS rid,
       created_at AS t,
       app_type AS app,
       provider_id AS pid,
       model AS model,
       input_tokens AS input,
       output_tokens AS output,
       cache_read_tokens AS cache_read,
       cache_creation_tokens AS cache_creation,
       input_token_semantics AS sem
FROM proxy_request_logs
WHERE status_code BETWEEN 200 AND 299
  AND (input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens) > 0
ORDER BY created_at
`;

const SQLITE_ARGS = ['-readonly', '-json', '-cmd', '.timeout 800'];
const MAX_FILES = 4000;
const MAX_FILE_BYTES = 64 * 1024 * 1024;

const fileCache = new Map();
let dbCache = { key: '', rows: [], apps: new Set(), allApps: new Set() };
let lastInfo = { detections: [], errors: [], config: { file: '', url: '' } };

function exists(target) {
  try {
    return fs.existsSync(target);
  } catch {
    return false;
  }
}

function toNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function parseTime(value, fallback) {
  if (value == null || value === '') return fallback;
  if (typeof value === 'number' || /^\d+$/.test(String(value))) {
    const n = Number(value);
    if (!Number.isFinite(n)) return fallback;
    return n > 10000000000 ? n : n * 1000;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function dbCandidates() {
  const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const roaming = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  const home = os.homedir();
  return [
    path.join(local, 'Wetokens', 'switch', 'cc-switch.db'),
    path.join(roaming, 'Wetokens', 'switch', 'cc-switch.db'),
    path.join(roaming, 'cc-switch', 'cc-switch.db'),
    path.join(local, 'cc-switch', 'cc-switch.db'),
    path.join(home, '.cc-switch', 'cc-switch.db'),
  ];
}

function findDb() {
  return dbCandidates().find((candidate) => exists(candidate)) || null;
}

function readConfig() {
  const empty = { file: '', url: '' };
  try {
    const raw = JSON.parse(fs.readFileSync(paths.localSourceFile(), 'utf8'));
    return {
      file: typeof raw.file === 'string' ? raw.file : '',
      url: typeof raw.url === 'string' ? raw.url : '',
    };
  } catch {
    return empty;
  }
}

function saveConfig(config) {
  const next = {
    file: typeof config.file === 'string' ? config.file.trim() : '',
    url: typeof config.url === 'string' ? config.url.trim() : '',
  };
  paths.ensureDir(paths.dataDir());
  fs.writeFileSync(paths.localSourceFile(), JSON.stringify(next, null, 2), 'utf8');
  return next;
}

function isLocalUrl(text) {
  try {
    const url = new URL(text);
    if (!['http:', 'https:'].includes(url.protocol)) return false;
    const host = url.hostname.toLowerCase();
    if (host === 'localhost' || host === '::1' || host === '[::1]') return true;
    if (/^127\./.test(host)) return true;
    if (/^10\./.test(host)) return true;
    if (/^192\.168\./.test(host)) return true;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return true;
    return false;
  } catch {
    return false;
  }
}

function dbCacheKey(db) {
  const parts = [];
  for (const suffix of ['', '-wal', '-shm']) {
    const file = `${db}${suffix}`;
    try {
      const stat = fs.statSync(file);
      parts.push(`${stat.size}:${stat.mtimeMs}`);
    } catch {
      parts.push('-');
    }
  }
  return parts.join('|');
}

function rowsFromDb(stdout, opencodeReady) {
  const rows = [];
  const apps = new Set();
  const allApps = new Set();
  const seen = new Set();
  let parsed;
  try {
    parsed = JSON.parse(stdout || '[]');
  } catch {
    return { rows, apps, allApps };
  }
  for (const item of parsed) {
    const provider = String(item.app || 'local').toLowerCase();
    allApps.add(provider);
    if (provider === 'opencode' && opencodeReady) continue;
    const rid = String(item.rid || '');
    if (rid && seen.has(rid)) continue;
    if (rid) seen.add(rid);

    const input = Math.max(0, toNumber(item.input));
    const hit = Math.max(0, toNumber(item.cache_read));
    const creation = Math.max(0, toNumber(item.cache_creation));
    const output = Math.max(0, toNumber(item.output));
    const semantics = toNumber(item.sem);
    const miss = semantics === 1
      ? Math.max(0, input - hit) + creation
      : input + creation;
    if (hit + miss + output <= 0) continue;

    const t = parseTime(item.t, Date.now());
    rows.push({
      t,
      input: miss,
      output,
      reasoning: 0,
      cache_read: hit,
      cache_write: 0,
      model_id: String(item.model || 'unknown'),
      provider_id: provider,
    });
    apps.add(provider);
  }
  return { rows, apps, allApps };
}

async function loadDb(db, opencodeReady) {
  const key = dbCacheKey(db);
  if (key && key === dbCache.key) return dbCache;
  const { stdout } = await execFileAsync(
    paths.sqliteBinary() || 'sqlite3',
    [...SQLITE_ARGS, db, DB_SQL],
    { maxBuffer: 512 * 1024 * 1024, timeout: 120000, encoding: 'utf8' },
  );
  const result = rowsFromDb(stdout, opencodeReady);
  dbCache = { key, ...result };
  return dbCache;
}

function loadDbSync(db, opencodeReady) {
  const key = dbCacheKey(db);
  if (key && key === dbCache.key) return dbCache;
  const stdout = execFileSync(
    paths.sqliteBinary() || 'sqlite3',
    [...SQLITE_ARGS, db, DB_SQL],
    { maxBuffer: 512 * 1024 * 1024, timeout: 120000, encoding: 'utf8' },
  );
  const result = rowsFromDb(stdout, opencodeReady);
  dbCache = { key, ...result };
  return dbCache;
}

function pick(object, keys) {
  for (const key of keys) {
    if (object[key] != null && object[key] !== '') return object[key];
  }
  return undefined;
}

function standardizeRecord(raw, fallbackProvider = 'local', fallbackTime = Date.now()) {
  if (!raw || typeof raw !== 'object') return null;
  const app = pick(raw, ['app', 'app_type', 'source', 'application', 'tool']);
  const givenProvider = pick(raw, ['provider', 'provider_id']);
  const provider = fallbackProvider;

  const hit = Math.max(0, toNumber(pick(raw, [
    'hit', 'cache_read', 'cache_read_tokens', 'cacheReadInputTokens',
    'cached_input_tokens', 'cachedInputTokens', 'cached', 'cacheReadTokens',
  ])));
  const creation = Math.max(0, toNumber(pick(raw, [
    'cache_creation', 'cache_creation_tokens', 'cache_creation_input_tokens',
    'cacheCreationInputTokens', 'cache_write', 'cacheWriteTokens',
  ])));
  const directMiss = pick(raw, [
    'miss', 'uncached_input', 'uncached_input_tokens', 'uncached', 'miss_tokens',
  ]);
  const inputRaw = pick(raw, [
    'input', 'input_tokens', 'prompt_tokens', 'inputTokens', 'promptTokens',
  ]);
  const output = Math.max(0, toNumber(pick(raw, [
    'output', 'output_tokens', 'completion_tokens', 'outputTokens', 'completionTokens',
  ])));

  let miss;
  if (directMiss != null) {
    miss = Math.max(0, toNumber(directMiss));
  } else {
    const input = Math.max(0, toNumber(inputRaw));
    miss = input >= hit ? input - hit : input;
    miss += creation;
  }
  if (hit + miss + output <= 0) return null;

  let model = String(pick(raw, ['model', 'model_id', 'modelID', 'name']) || 'unknown');
  if (givenProvider && givenProvider !== provider) model = `${givenProvider} / ${model}`;
  if (app && app !== provider) model = `${app} / ${model}`;

  return {
    time: parseTime(pick(raw, ['time', 'timestamp', 'created_at', 'createdAt', 'date']), fallbackTime),
    provider,
    model,
    hit,
    miss,
    output,
  };
}

function standardizePayload(data, fallbackProvider = 'local', fallbackTime = Date.now()) {
  let list = [];
  if (Array.isArray(data)) {
    list = data;
  } else if (data && typeof data === 'object') {
    const nested = data.records || data.items || data.data || data.usage || data.entries;
    if (Array.isArray(nested)) list = nested;
    else list = [data];
  } else {
    return [];
  }
  return list
    .map((item) => standardizeRecord(item, fallbackProvider, fallbackTime))
    .filter(Boolean);
}

function parseFlexibleContent(text, fallbackProvider = 'local', fallbackTime = Date.now()) {
  const trimmed = String(text || '').trim();
  if (!trimmed) return [];
  try {
    const parsed = JSON.parse(trimmed);
    return standardizePayload(parsed, fallbackProvider, fallbackTime);
  } catch {
    const records = [];
    for (const line of trimmed.split(/\r?\n/)) {
      const row = line.trim();
      if (!row || (!row.startsWith('{') && !row.startsWith('['))) continue;
      try {
        records.push(...standardizePayload(JSON.parse(row), fallbackProvider, fallbackTime));
      } catch {
        // 跳过坏行
      }
    }
    return records;
  }
}

function rawRows(records) {
  return records.map((record) => ({
    t: record.time,
    input: record.miss,
    output: record.output,
    reasoning: 0,
    cache_read: record.hit,
    cache_write: 0,
    model_id: record.model,
    provider_id: record.provider,
  }));
}

function parseClaudeText(text, fallbackTime) {
  const out = [];
  const seen = new Set();
  for (const line of String(text || '').split(/\r?\n/)) {
    if (!line.trim()) continue;
    let item;
    try {
      item = JSON.parse(line);
    } catch {
      continue;
    }
    if (item.type !== 'assistant') continue;
    const usage = item.message && item.message.usage;
    if (!usage) continue;
    const id = (item.message && item.message.id) || item.uuid || item.parentUuid;
    if (id && seen.has(id)) continue;
    if (id) seen.add(id);
    const hit = Math.max(0, toNumber(usage.cache_read_input_tokens));
    const miss = Math.max(0, toNumber(usage.input_tokens))
      + Math.max(0, toNumber(usage.cache_creation_input_tokens));
    const output = Math.max(0, toNumber(usage.output_tokens));
    if (hit + miss + output <= 0) continue;
    out.push({
      time: parseTime(item.timestamp, fallbackTime),
      provider: 'claude',
      model: String((item.message && item.message.model) || 'claude'),
      hit,
      miss,
      output,
    });
  }
  return out;
}

function parseCodexText(text, fallbackTime) {
  const out = [];
  let model = 'codex';
  let sawLast = false;
  let maxTotal = null;
  let maxTotalTime = fallbackTime;
  for (const line of String(text || '').split(/\r?\n/)) {
    if (!line.trim()) continue;
    let item;
    try {
      item = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = item.payload || {};
    const candidate = payload.model || payload.model_name || payload.modelName
      || (payload.info && payload.info.model);
    if (candidate) model = String(candidate);
    if (payload.type !== 'token_count') continue;
    const info = payload.info || {};
    const usage = info.last_token_usage;
    const time = parseTime(item.timestamp, fallbackTime);
    if (usage) {
      sawLast = true;
      const input = Math.max(0, toNumber(usage.input_tokens));
      const hit = Math.max(0, toNumber(usage.cached_input_tokens));
      const output = Math.max(0, toNumber(usage.output_tokens));
      const miss = Math.max(0, input - hit);
      if (hit + miss + output > 0) {
        out.push({ time, provider: 'codex', model, hit, miss, output });
      }
    } else if (info.total_token_usage) {
      maxTotal = info.total_token_usage;
      maxTotalTime = time;
    }
  }
  if (!sawLast && maxTotal) {
    const input = Math.max(0, toNumber(maxTotal.input_tokens));
    const hit = Math.max(0, toNumber(maxTotal.cached_input_tokens));
    const output = Math.max(0, toNumber(maxTotal.output_tokens));
    const miss = Math.max(0, input - hit);
    if (hit + miss + output > 0) {
      out.push({ time: maxTotalTime, provider: 'codex', model, hit, miss, output });
    }
  }
  return out;
}

function collectGeminiTokens(node, ctx, out, prefix) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    node.forEach((item, index) => collectGeminiTokens(item, ctx, out, `${prefix}.${index}`));
    return;
  }
  const tokens = node.tokens || node.tokenUsage || node.usage;
  if (tokens && typeof tokens === 'object') {
    const hit = Math.max(0, toNumber(pick(tokens, ['cached', 'cache_read', 'cachedContentTokenCount', 'cacheRead'])));
    const input = Math.max(0, toNumber(pick(tokens, ['input', 'input_tokens', 'promptTokenCount', 'prompt'])));
    const output = Math.max(0, toNumber(pick(tokens, ['output', 'output_tokens', 'candidatesTokenCount', 'completion'])));
    const miss = input >= hit ? input - hit : input;
    if (hit + miss + output > 0) {
      out.push({
        time: parseTime(pick(node, ['timestamp', 'time', 'created_at', 'createdAt']), ctx.time),
        provider: 'gemini',
        model: String(pick(node, ['model', 'model_id', 'modelId']) || ctx.model || 'gemini'),
        hit,
        miss,
        output,
      });
    }
  }
  const nextTime = parseTime(pick(node, ['timestamp', 'time', 'created_at', 'createdAt']), ctx.time);
  const nextModel = String(pick(node, ['model', 'model_id', 'modelId']) || ctx.model || 'gemini');
  for (const [key, value] of Object.entries(node)) {
    if (key === 'tokens' || key === 'tokenUsage' || key === 'usage') continue;
    collectGeminiTokens(value, { time: nextTime, model: nextModel }, out, `${prefix}.${key}`);
  }
}

function parseGeminiText(text, fallbackTime) {
  const out = [];
  const source = String(text || '').trim();
  if (!source) return out;
  let parsed = null;
  try {
    parsed = JSON.parse(source);
  } catch {
    parsed = null;
  }
  if (parsed) {
    collectGeminiTokens(parsed, { time: fallbackTime, model: 'gemini' }, out, 'root');
    return out;
  }
  for (const line of source.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      collectGeminiTokens(JSON.parse(line), { time: fallbackTime, model: 'gemini' }, out, 'line');
    } catch {
      // 跳过坏行
    }
  }
  return out;
}

async function walkFiles(root, extensions, limit = MAX_FILES) {
  const found = [];
  const queue = [root];
  while (queue.length > 0 && found.length < limit) {
    const dir = queue.shift();
    let entries;
    try {
      entries = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) queue.push(full);
      else if (entry.isFile() && extensions.some((ext) => entry.name.toLowerCase().endsWith(ext))) {
        found.push(full);
        if (found.length >= limit) break;
      }
    }
  }
  return found;
}

function walkFilesSync(root, extensions, limit = MAX_FILES) {
  const found = [];
  const queue = [root];
  while (queue.length > 0 && found.length < limit) {
    const dir = queue.shift();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) queue.push(full);
      else if (entry.isFile() && extensions.some((ext) => entry.name.toLowerCase().endsWith(ext))) {
        found.push(full);
        if (found.length >= limit) break;
      }
    }
  }
  return found;
}

async function parseFiles(files, parser) {
  const records = [];
  for (const file of files) {
    let stat;
    try {
      stat = await fsp.stat(file);
    } catch {
      continue;
    }
    if (stat.size > MAX_FILE_BYTES) continue;
    const key = `${stat.size}:${stat.mtimeMs}`;
    const cached = fileCache.get(file);
    if (cached && cached.key === key) {
      records.push(...cached.records);
      continue;
    }
    let text;
    try {
      text = await fsp.readFile(file, 'utf8');
    } catch {
      continue;
    }
    const parsed = parser(text, stat.mtimeMs);
    fileCache.set(file, { key, records: parsed });
    records.push(...parsed);
  }
  return records;
}

function parseFilesSync(files, parser) {
  const records = [];
  for (const file of files) {
    let stat;
    try {
      stat = fs.statSync(file);
    } catch {
      continue;
    }
    if (stat.size > MAX_FILE_BYTES) continue;
    const key = `${stat.size}:${stat.mtimeMs}`;
    const cached = fileCache.get(file);
    if (cached && cached.key === key) {
      records.push(...cached.records);
      continue;
    }
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const parsed = parser(text, stat.mtimeMs);
    fileCache.set(file, { key, records: parsed });
    records.push(...parsed);
  }
  return records;
}

function claudeRoots() {
  return [
    path.join(os.homedir(), '.claude', 'projects'),
    path.join(process.env.APPDATA || '', 'Claude', 'projects'),
  ].filter((item) => item && exists(item));
}

function codexRoots() {
  return [
    path.join(os.homedir(), '.codex', 'sessions'),
    path.join(os.homedir(), '.codex', 'archived_sessions'),
  ].filter((item) => exists(item));
}

function geminiRoots() {
  return [
    path.join(os.homedir(), '.gemini', 'tmp'),
    path.join(os.homedir(), '.gemini'),
  ].filter((item) => exists(item));
}

function localGenericFiles(target) {
  if (!target) return [];
  if (!exists(target)) return [];
  const stat = fs.statSync(target);
  if (stat.isFile()) return [target];
  if (stat.isDirectory()) return walkFilesSync(target, ['.json', '.jsonl']);
  return [];
}

function loadCollected() {
  let content;
  try {
    content = fs.readFileSync(paths.localUsageFile(), 'utf8');
  } catch {
    return [];
  }
  const records = [];
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const item = standardizeRecord(JSON.parse(line), 'local', Date.now());
      if (item) records.push(item);
    } catch {
      // 跳过坏行
    }
  }
  return records;
}

function genericRecordsSync(config) {
  const records = [];
  for (const file of localGenericFiles(config.file)) {
    try {
      const stat = fs.statSync(file);
      const key = `generic:${stat.size}:${stat.mtimeMs}`;
      const cached = fileCache.get(file);
      if (cached && cached.key === key) {
        records.push(...cached.records);
        continue;
      }
      const parsed = parseFlexibleContent(fs.readFileSync(file, 'utf8'), 'local', stat.mtimeMs);
      fileCache.set(file, { key, records: parsed });
      records.push(...parsed);
    } catch {
      // 跳过读不了的文件
    }
  }
  return records;
}

async function genericRecords(config, errors) {
  const records = [];
  if (config.file) {
    for (const file of localGenericFiles(config.file)) {
      try {
        const stat = await fsp.stat(file);
        const key = `generic:${stat.size}:${stat.mtimeMs}`;
        const cached = fileCache.get(file);
        if (cached && cached.key === key) {
          records.push(...cached.records);
          continue;
        }
        const parsed = parseFlexibleContent(await fsp.readFile(file, 'utf8'), 'local', stat.mtimeMs);
        fileCache.set(file, { key, records: parsed });
        records.push(...parsed);
      } catch (error) {
        errors.push(`本地文件读取失败：${error.message || file}`);
      }
    }
  }
  if (config.url) {
    if (!isLocalUrl(config.url)) {
      errors.push('本地接口地址必须是 localhost / 127.0.0.1 / 内网地址');
    } else {
      try {
        const response = await fetch(config.url, {
          headers: { Accept: 'application/json, text/plain' },
          signal: AbortSignal.timeout(8000),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = await response.text();
        records.push(...parseFlexibleContent(text, 'local', Date.now()));
      } catch (error) {
        errors.push(`本地接口请求失败：${error.message || '未知错误'}`);
      }
    }
  }
  return records;
}

function opencodeReady() {
  return Boolean(paths.opencodeDb());
}

function detection(id, label, detail, count) {
  return { id, label, detail, count, available: count > 0 };
}

async function load() {
  const config = readConfig();
  const errors = [];
  const raw = [];
  const detections = [];
  let dbPath = null;
  let dbApps = new Set();
  const ready = opencodeReady();

  const db = findDb();
  if (db) {
    try {
      const result = await loadDb(db, ready);
      dbPath = db;
      dbApps = result.apps;
      raw.push(...result.rows);
      const detail = result.allApps.size > result.apps.size
        ? '仅含 OpenCode 记录（已由 OpenCode 单独统计）'
        : db;
      detections.push(detection('wetokens', 'Wetokens 本地数据库', detail, result.rows.length));
    } catch (error) {
      errors.push(`Wetokens 数据库读取失败：${error.message || '未知错误'}`);
    }
  } else {
    detections.push(detection('wetokens', 'Wetokens 本地数据库', '未发现', 0));
  }

  if (!dbApps.has('claude')) {
    const roots = claudeRoots();
    const files = [];
    for (const root of roots) files.push(...await walkFiles(root, ['.jsonl']));
    const records = await parseFiles(files, parseClaudeText);
    raw.push(...rawRows(records));
    detections.push(detection('claude', 'Claude Code', roots[0] || '未发现 ~/.claude/projects', records.length));
  } else {
    detections.push(detection('claude', 'Claude Code', '由 Wetokens 数据库提供', dbApps.has('claude') ? 1 : 0));
  }

  if (!dbApps.has('codex')) {
    const roots = codexRoots();
    const files = [];
    for (const root of roots) files.push(...await walkFiles(root, ['.jsonl']));
    const records = await parseFiles(files, parseCodexText);
    raw.push(...rawRows(records));
    detections.push(detection('codex', 'Codex', roots[0] || '未发现 ~/.codex/sessions', records.length));
  } else {
    detections.push(detection('codex', 'Codex', '由 Wetokens 数据库提供', 1));
  }

  if (!dbApps.has('gemini')) {
    const roots = geminiRoots();
    const files = [];
    for (const root of roots) files.push(...await walkFiles(root, ['.json', '.jsonl']));
    const records = await parseFiles(files, parseGeminiText);
    raw.push(...rawRows(records));
    detections.push(detection('gemini', 'Gemini CLI', roots[0] || '未发现 ~/.gemini', records.length));
  } else {
    detections.push(detection('gemini', 'Gemini CLI', '由 Wetokens 数据库提供', 1));
  }

  const generic = await genericRecords(config, errors);
  raw.push(...rawRows(generic));
  if (config.file || config.url) {
    detections.push(detection('generic', '本地接口', config.file || config.url, generic.length));
  }

  const collected = loadCollected();
  raw.push(...rawRows(collected));
  if (collected.length > 0) {
    detections.push(detection('collector', '收集接口记录', paths.localUsageFile(), collected.length));
  }

  lastInfo = { detections, errors, config, db: dbPath };
  return { records: raw, detections, errors, config, db: dbPath, genericCount: generic.length + collected.length };
}

function loadSync() {
  const config = readConfig();
  const errors = [];
  const raw = [];
  const detections = [];
  let dbPath = null;
  let dbApps = new Set();
  const ready = opencodeReady();

  const db = findDb();
  if (db) {
    try {
      const result = loadDbSync(db, ready);
      dbPath = db;
      dbApps = result.apps;
      raw.push(...result.rows);
      detections.push(detection('wetokens', 'Wetokens 本地数据库', db, result.rows.length));
    } catch (error) {
      errors.push(`Wetokens 数据库读取失败：${error.message || '未知错误'}`);
    }
  }

  if (!dbApps.has('claude')) {
    const files = [];
    for (const root of claudeRoots()) files.push(...walkFilesSync(root, ['.jsonl']));
    const records = parseFilesSync(files, parseClaudeText);
    raw.push(...rawRows(records));
    detections.push(detection('claude', 'Claude Code', '本地日志', records.length));
  }
  if (!dbApps.has('codex')) {
    const files = [];
    for (const root of codexRoots()) files.push(...walkFilesSync(root, ['.jsonl']));
    const records = parseFilesSync(files, parseCodexText);
    raw.push(...rawRows(records));
    detections.push(detection('codex', 'Codex', '本地日志', records.length));
  }
  if (!dbApps.has('gemini')) {
    const files = [];
    for (const root of geminiRoots()) files.push(...walkFilesSync(root, ['.json', '.jsonl']));
    const records = parseFilesSync(files, parseGeminiText);
    raw.push(...rawRows(records));
    detections.push(detection('gemini', 'Gemini CLI', '本地日志', records.length));
  }

  const generic = genericRecordsSync(config);
  raw.push(...rawRows(generic));
  const collected = loadCollected();
  raw.push(...rawRows(collected));

  lastInfo = { detections, errors, config, db: dbPath };
  return { records: raw, detections, errors, config, db: dbPath };
}

function getInfo() {
  return lastInfo;
}

module.exports = {
  APP_LABELS,
  LOCAL_APP_IDS,
  load,
  loadSync,
  getInfo,
  readConfig,
  saveConfig,
  isLocalUrl,
  standardizePayload,
  localGenericFiles,
  findDb,
};
