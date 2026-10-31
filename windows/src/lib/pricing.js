'use strict';

const fs = require('fs');
const paths = require('./paths');

const SOURCE_URL = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing.md';
const REFRESH_INTERVAL = 30 * 24 * 60 * 60 * 1000; // 每月检查一次

const TIERS = {
  flash: { id: 'flash', name: 'Flash', modelID: 'deepseek-flash' },
  pro: { id: 'pro', name: 'Pro', modelID: 'deepseek-v4-pro' },
};

function table(hitOff, hitPeak, missOff, missPeak, outputOff, outputPeak) {
  return { hitOff, hitPeak, missOff, missPeak, outputOff, outputPeak };
}

const DEFAULTS = {
  flash: table(0.02, 0.04, 1.0, 2.0, 4.0, 8.0),
  pro: table(0.15, 0.3, 4.5, 9.0, 13.5, 27.0),
};

let tables = {
  flash: { ...DEFAULTS.flash },
  pro: { ...DEFAULTS.pro },
};
let updatedAt = null;
let updating = false;
let updateFailed = false;
let lastAttempt = 0;

function price(tier, peak) {
  const t = tables[tier] || DEFAULTS.flash;
  return {
    hit: peak ? t.hitPeak : t.hitOff,
    miss: peak ? t.missPeak : t.missOff,
    output: peak ? t.outputPeak : t.outputOff,
  };
}

function cost(tier, peak, hit, miss, output) {
  const p = price(tier, peak);
  return ((hit || 0) * p.hit + (miss || 0) * p.miss + (output || 0) * p.output) / 1000000;
}

function parseMoney(text) {
  const cleaned = String(text)
    .replace(/元/g, '')
    .replace(/,/g, '')
    .trim();
  const value = Number(cleaned);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function tableFrom(values) {
  const needed = ['hit_off', 'hit_peak', 'miss_off', 'miss_peak', 'output_off', 'output_peak'];
  if (!needed.every((key) => Number.isFinite(values[key]))) return null;
  if (values.hit_off > values.hit_peak) return null;
  if (values.miss_off > values.miss_peak) return null;
  if (values.output_off > values.output_peak) return null;
  return {
    hitOff: values.hit_off,
    hitPeak: values.hit_peak,
    missOff: values.miss_off,
    missPeak: values.miss_peak,
    outputOff: values.output_off,
    outputPeak: values.output_peak,
  };
}

function parse(markdown) {
  const flash = {};
  const pro = {};
  for (const raw of markdown.split(/\r?\n/)) {
    if (!raw.includes('| 价格')) continue;
    const columns = raw.split('|').map((s) => s.trim()).filter((s) => s.length > 0);
    if (columns.length < 5 || !columns[0].startsWith('价格')) continue;
    const category = columns[1];
    const period = columns[2];
    const flashPrice = parseMoney(columns[3]);
    const proPrice = parseMoney(columns[4]);
    if (flashPrice == null || proPrice == null) continue;

    let key;
    if (category.includes('缓存未命中')) key = 'miss';
    else if (category.includes('缓存命中')) key = 'hit';
    else if (category.includes('输出')) key = 'output';
    else continue;

    const suffix = period.includes('高峰') ? 'peak' : 'off';
    flash[`${key}_${suffix}`] = flashPrice;
    pro[`${key}_${suffix}`] = proPrice;
  }
  const flashTable = tableFrom(flash);
  const proTable = tableFrom(pro);
  if (!flashTable || !proTable) return null;
  return { flash: flashTable, pro: proTable };
}

function loadCache() {
  try {
    const raw = fs.readFileSync(paths.pricingFile(), 'utf8');
    const cache = JSON.parse(raw);
    if (cache && cache.flash && cache.pro && Number.isFinite(cache.fetchedAt)) {
      tables = { flash: cache.flash, pro: cache.pro };
      updatedAt = cache.fetchedAt;
      return true;
    }
  } catch {
    // 没有缓存时使用内置价格
  }
  return false;
}

function saveCache() {
  try {
    paths.ensureDir(paths.dataDir());
    fs.writeFileSync(
      paths.pricingFile(),
      JSON.stringify({ fetchedAt: updatedAt, flash: tables.flash, pro: tables.pro }, null, 2),
      'utf8',
    );
  } catch {
    // 缓存失败不影响运行
  }
}

function needsRefresh(now = Date.now()) {
  if (!updatedAt) return true;
  return now - updatedAt > REFRESH_INTERVAL;
}

async function fetchNow() {
  if (updating) return { ok: false, error: '正在更新' };
  updating = true;
  updateFailed = false;
  lastAttempt = Date.now();
  try {
    const response = await fetch(SOURCE_URL, {
      headers: {
        Accept: 'text/markdown, text/html;q=0.9',
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      },
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = await response.text();
    const parsed = parse(text);
    if (!parsed) throw new Error('价格表解析失败');
    tables = parsed;
    updatedAt = Date.now();
    saveCache();
    return { ok: true };
  } catch (error) {
    updateFailed = true;
    return { ok: false, error: error.message || '网络请求失败' };
  } finally {
    updating = false;
  }
}

function refreshIfNeeded() {
  if (needsRefresh()) return fetchNow();
  return Promise.resolve(null);
}

function getState() {
  return {
    tiers: Object.values(TIERS),
    tables,
    updatedAt,
    updating,
    updateFailed,
    lastAttempt,
  };
}

module.exports = {
  TIERS,
  DEFAULTS,
  price,
  cost,
  parse,
  loadCache,
  fetchNow,
  refreshIfNeeded,
  needsRefresh,
  getState,
};
