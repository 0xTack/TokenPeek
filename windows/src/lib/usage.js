'use strict';

const { execFile, execFileSync } = require('child_process');
const { promisify } = require('util');
const paths = require('./paths');
const pricing = require('./pricing');
const peak = require('./peak');

const execFileAsync = promisify(execFile);

const SQL = `
SELECT time_created AS t,
       json_extract(data, '$.tokens.input') AS input,
       json_extract(data, '$.tokens.output') AS output,
       json_extract(data, '$.tokens.reasoning') AS reasoning,
       json_extract(data, '$.tokens.cache.read') AS cache_read,
       json_extract(data, '$.tokens.cache.write') AS cache_write,
       json_extract(data, '$.model.id') AS model_id,
       json_extract(data, '$.model.providerID') AS provider_id
FROM session_message
WHERE type = 'assistant'
  AND json_extract(data, '$.tokens') IS NOT NULL
`;

const SQLITE_ARGS = ['-readonly', '-json', '-cmd', '.timeout 800'];

const THIRD_PARTY = new Set([
  'claude', 'claude-desktop', 'codex', 'gemini', 'grokbuild',
  'openclaw', 'hermes', 'pi', 'local',
]);

function emptySet() {
  return {};
}

function add(bucketSet, provider, model, hit, miss, output, cost, savedFlash, savedPro) {
  const key = `${provider}|${model}`;
  let bucket = bucketSet[key];
  if (!bucket) {
    bucket = {
      provider,
      model,
      hit: 0,
      miss: 0,
      output: 0,
      cost: 0,
      savedFlash: 0,
      savedPro: 0,
    };
    bucketSet[key] = bucket;
  }
  bucket.hit += hit;
  bucket.miss += miss;
  bucket.output += output;
  bucket.cost += cost;
  bucket.savedFlash += savedFlash;
  bucket.savedPro += savedPro;
}

function parseRows(stdout) {
  const text = (stdout || '').trim();
  if (!text) return [];
  return JSON.parse(text);
}

async function runSql(db, sql, sqlite) {
  const { stdout } = await execFileAsync(
    sqlite,
    [...SQLITE_ARGS, db, sql],
    { maxBuffer: 512 * 1024 * 1024, timeout: 120000, encoding: 'utf8' },
  );
  return parseRows(stdout);
}

function runSqlSync(db, sql, sqlite) {
  const stdout = execFileSync(
    sqlite,
    [...SQLITE_ARGS, db, sql],
    { maxBuffer: 512 * 1024 * 1024, timeout: 120000, encoding: 'utf8' },
  );
  return parseRows(stdout);
}

function aggregate(rows, now, extra = []) {
  const startToday = peak.startOfDay(now);
  const startWeek = peak.startOfWeek(now);
  const startMonth = peak.startOfMonth(now);

  const today = emptySet();
  const week = emptySet();
  const month = emptySet();
  const allTime = emptySet();
  const dailyMap = new Map();

  for (const row of [...rows, ...extra]) {
    const provider = String(row.provider_id || '').toLowerCase();
    const model = String(row.model_id || '');
    if (!provider || !model) continue;
    // 免费模型不计入用量
    if (provider === 'opencode') continue;
    if (model.toLowerCase().includes('-free')) continue;

    const date = Number(row.t);
    if (!Number.isFinite(date)) continue;
    const input = Math.max(0, Number(row.input) || 0);
    const output = Math.max(0, Number(row.output) || 0);
    const reasoning = Math.max(0, Number(row.reasoning) || 0);
    const cacheRead = Math.max(0, Number(row.cache_read) || 0);
    const cacheWrite = Math.max(0, Number(row.cache_write) || 0);

    const hit = cacheRead;
    const miss = input + cacheWrite;
    const out = output + reasoning;
    if (hit + miss + out <= 0) continue;

    // 成本按每条记录当时的高峰/空闲价计算
    const tier = model.toLowerCase().includes('pro') ? 'pro' : 'flash';
    const isPeak = peak.isPeak(date);
    const deepseek = provider === 'deepseek';
    const thirdParty = THIRD_PARTY.has(provider);
    const cost = deepseek ? pricing.cost(tier, isPeak, hit, miss, out) : 0;
    const savedFlash = !deepseek && !thirdParty ? pricing.cost('flash', isPeak, hit, miss, out) : 0;
    const savedPro = !deepseek && !thirdParty ? pricing.cost('pro', isPeak, hit, miss, out) : 0;

    add(allTime, provider, model, hit, miss, out, cost, savedFlash, savedPro);
    if (date >= startToday) add(today, provider, model, hit, miss, out, cost, savedFlash, savedPro);
    if (date >= startWeek) add(week, provider, model, hit, miss, out, cost, savedFlash, savedPro);
    if (date >= startMonth) add(month, provider, model, hit, miss, out, cost, savedFlash, savedPro);

    if (date >= startWeek) {
      const key = peak.dayKey(date);
      const current = dailyMap.get(key) || { date: peak.startOfDay(date), hit: 0, miss: 0 };
      current.hit += hit;
      current.miss += miss;
      dailyMap.set(key, current);
    }
  }

  const daily = [];
  for (let offset = 6; offset >= 0; offset -= 1) {
    const ts = startToday - offset * peak.DAY;
    const item = dailyMap.get(peak.dayKey(ts)) || { date: peak.startOfDay(ts), hit: 0, miss: 0 };
    daily.push({ date: item.date, hit: item.hit, miss: item.miss });
  }

  const providers = new Set(['deepseek']);
  for (const set of [today, week, month, allTime]) {
    for (const bucket of Object.values(set)) providers.add(bucket.provider);
  }

  return {
    status: 'ready',
    today,
    week,
    month,
    allTime,
    daily,
    providers: [...providers].sort(),
  };
}

function resolveDatabase() {
  const db = paths.opencodeDb();
  if (!db) return { error: { status: 'unavailable' } };
  const sqlite = paths.sqliteBinary();
  if (!sqlite) return { error: { status: 'failed', error: '缺少 sqlite3 组件' } };
  return { db, sqlite };
}

async function load(now = Date.now(), extra = []) {
  const target = resolveDatabase();
  if (target.error) {
    if (extra.length > 0) return { ...aggregate([], now, extra), database: null };
    return target.error;
  }
  let rows;
  try {
    rows = await runSql(target.db, SQL, target.sqlite);
  } catch (error) {
    return { status: 'failed', error: error.message || '读取用量失败' };
  }
  return { ...aggregate(rows, now, extra), database: target.db };
}

function loadSync(now = Date.now(), extra = []) {
  const target = resolveDatabase();
  if (target.error) {
    if (extra.length > 0) return { ...aggregate([], now, extra), database: null };
    return target.error;
  }
  let rows;
  try {
    rows = runSqlSync(target.db, SQL, target.sqlite);
  } catch (error) {
    return { status: 'failed', error: error.message || '读取用量失败' };
  }
  return { ...aggregate(rows, now, extra), database: target.db };
}

module.exports = { load, loadSync, SQL };
