'use strict';

const fs = require('fs');
const paths = require('./paths');
const pricing = require('./pricing');
const peak = require('./peak');

function valueOf(args, name) {
  const index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

function report(args) {
  const app = (valueOf(args, '--app') || '').trim();
  if (!app) {
    return {
      ok: false,
      message:
        '用法：DeepSeekDashboard.exe --report --app <名称> [--model deepseek-flash] [--hit N] [--miss N] [--output N] [--cost N] [--time ISO8601]',
    };
  }
  const model = valueOf(args, '--model') || 'deepseek-flash';
  const hit = Math.max(0, Number.parseInt(valueOf(args, '--hit') || '0', 10) || 0);
  const miss = Math.max(0, Number.parseInt(valueOf(args, '--miss') || '0', 10) || 0);
  const output = Math.max(0, Number.parseInt(valueOf(args, '--output') || '0', 10) || 0);
  const costText = valueOf(args, '--cost');
  const cost = costText == null || costText === '' ? null : Number(costText);
  const time = valueOf(args, '--time') || new Date().toISOString();

  const record = {
    app,
    time,
    model,
    hit,
    miss,
    output,
    ...(Number.isFinite(cost) ? { cost } : {}),
  };

  try {
    paths.ensureDir(paths.dataDir());
    fs.appendFileSync(paths.customFile(), `${JSON.stringify(record)}\n`, 'utf8');
    return { ok: true, message: `已记录：${app} · ${hit + miss + output} tokens` };
  } catch (error) {
    return { ok: false, message: `写入失败：${paths.customFile()}（${error.message}）` };
  }
}

function parseDate(record, fallback) {
  if (Number.isFinite(record.timestamp)) {
    const ts = record.timestamp > 10000000000 ? record.timestamp : record.timestamp * 1000;
    return ts;
  }
  if (record.time) {
    const parsed = Date.parse(record.time);
    if (Number.isFinite(parsed)) return parsed;
    const local = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(record.time);
    if (local) {
      return peak.toBeijing(+local[1], +local[2], +local[3], +local[4], +local[5], +(local[6] || 0));
    }
  }
  return fallback;
}

function emptyUsage() {
  return {};
}

function add(usage, app, bucket) {
  let current = usage[app];
  if (!current) {
    current = { app, hit: 0, miss: 0, output: 0, cost: 0 };
    usage[app] = current;
  }
  current.hit += bucket.hit;
  current.miss += bucket.miss;
  current.output += bucket.output;
  current.cost += bucket.cost;
}

function load(now = Date.now()) {
  let content;
  try {
    content = fs.readFileSync(paths.customFile(), 'utf8');
  } catch {
    return null;
  }

  const startToday = peak.startOfDay(now);
  const startWeek = peak.startOfWeek(now);
  const startMonth = peak.startOfMonth(now);

  const snapshot = {
    all: emptyUsage(),
    today: emptyUsage(),
    week: emptyUsage(),
    month: emptyUsage(),
    daily: [],
  };
  const dailyMap = new Map();
  let valid = 0;

  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    const app = String(record.app || '').trim();
    if (!app) continue;

    const hit = Math.max(0, Number(record.hit) || 0);
    const miss = Math.max(0, Number(record.miss) || 0);
    const output = Math.max(0, Number(record.output) || 0);
    if (hit + miss + output <= 0) continue;

    const date = parseDate(record, now);
    const model = String(record.model || 'deepseek-flash');
    const tier = model.toLowerCase().includes('pro') ? 'pro' : 'flash';
    const cost = Number.isFinite(record.cost)
      ? Number(record.cost)
      : pricing.cost(tier, peak.isPeak(date), hit, miss, output);
    const bucket = { hit, miss, output, cost };

    valid += 1;
    add(snapshot.all, app, bucket);
    if (date >= startToday) add(snapshot.today, app, bucket);
    if (date >= startWeek) {
      add(snapshot.week, app, bucket);
      const key = peak.dayKey(date);
      const day = dailyMap.get(key) || { date: peak.startOfDay(date), hit: 0, miss: 0 };
      day.hit += hit;
      day.miss += miss;
      dailyMap.set(key, day);
    }
    if (date >= startMonth) add(snapshot.month, app, bucket);
  }

  if (valid === 0) return snapshot;

  for (let offset = 6; offset >= 0; offset -= 1) {
    const ts = startToday - offset * peak.DAY;
    const item = dailyMap.get(peak.dayKey(ts)) || { date: peak.startOfDay(ts), hit: 0, miss: 0 };
    snapshot.daily.push({ date: item.date, hit: item.hit, miss: item.miss });
  }
  return snapshot;
}

module.exports = { report, load, file: paths.customFile };
