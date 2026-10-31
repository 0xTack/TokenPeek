'use strict';

const peak = require('./peak');
const pricing = require('./pricing');
const customLib = require('./custom');
const format = require('./format');
const { APP_LABELS, LOCAL_APP_IDS } = require('./localusage');

const PERIODS = [
  { id: 'today', label: '今日' },
  { id: 'week', label: '近 7 天' },
  { id: 'month', label: '本月' },
  { id: 'all', label: '全部' },
];

const PROVIDER_NAMES = {
  deepseek: 'DeepSeek',
  ollama: 'Ollama',
  opencode: '免费模型',
  ...APP_LABELS,
};

function isLocalApp(id) {
  return LOCAL_APP_IDS.has(id);
}

function providerName(id) {
  return PROVIDER_NAMES[id] || (id ? id.charAt(0).toUpperCase() + id.slice(1) : id);
}

function providerLabel(id) {
  return providerName(id);
}

function tokensOf(bucket) {
  return (bucket.hit || 0) + (bucket.miss || 0) + (bucket.output || 0);
}

function emptyTotals() {
  return { hit: 0, miss: 0, output: 0, cost: 0, savedFlash: 0, savedPro: 0 };
}

function sumBuckets(list) {
  const total = emptyTotals();
  for (const bucket of list) {
    total.hit += bucket.hit || 0;
    total.miss += bucket.miss || 0;
    total.output += bucket.output || 0;
    total.cost += bucket.cost || 0;
    total.savedFlash += bucket.savedFlash || 0;
    total.savedPro += bucket.savedPro || 0;
  }
  return total;
}

function entriesOfSet(set, source) {
  if (!set) return [];
  const list = Object.values(set).filter((bucket) => source === 'all' || bucket.provider === source);
  return list
    .filter((bucket) => tokensOf(bucket) > 0 || bucket.cost > 0)
    .sort((a, b) => {
      const diff = tokensOf(b) - tokensOf(a);
      return diff !== 0 ? diff : a.model.localeCompare(b.model);
    });
}

function entriesOfCustom(usage) {
  if (!usage) return [];
  return Object.values(usage)
    .map((bucket) => ({ ...bucket, provider: 'custom', tokens: tokensOf(bucket) }))
    .filter((bucket) => bucket.tokens > 0 || bucket.cost > 0)
    .sort((a, b) => {
      const diff = b.tokens - a.tokens;
      return diff !== 0 ? diff : a.app.localeCompare(b.app);
    });
}

function sumCustom(usage) {
  const total = emptyTotals();
  for (const bucket of Object.values(usage || {})) {
    total.hit += bucket.hit || 0;
    total.miss += bucket.miss || 0;
    total.output += bucket.output || 0;
    total.cost += bucket.cost || 0;
  }
  return total;
}

function setForPeriod(usage, period) {
  if (!usage) return null;
  switch (period) {
    case 'today': return usage.today;
    case 'week': return usage.week;
    case 'month': return usage.month;
    default: return usage.allTime;
  }
}

function customForPeriod(snapshot, period) {
  if (!snapshot) return null;
  switch (period) {
    case 'today': return snapshot.today;
    case 'week': return snapshot.week;
    case 'month': return snapshot.month;
    default: return snapshot.all;
  }
}

function rateOf(total) {
  const denom = (total.hit || 0) + (total.miss || 0);
  if (denom <= 0) return null;
  return total.hit / denom;
}

function adviceText(rate, isLocal = false) {
  if (rate == null) {
    return isLocal
      ? '还没有输入数据；先在对应 App 里正常对话几轮再来看。'
      : '还没有输入数据；先在 OpenCode 里正常对话几轮再来看。';
  }
  const pct = (rate * 100).toFixed(1);
  if (rate >= 0.8) return `命中率 ${pct}%：缓存利用良好。继续在同一会话追问，尽量别改动开头的大段上下文。`;
  if (rate >= 0.5) return `命中率 ${pct}%：还有提升空间。保持会话连续，把稳定内容放前面、变化内容放后面。`;
  return `命中率 ${pct}%：偏低。少频繁新建会话或修改开头提示词，重复的大文件尽量复用同一份上下文。`;
}

function weekdayShort(timestamp) {
  return ['日', '一', '二', '三', '四', '五', '六'][peak.parts(timestamp).weekday];
}

function sourcesFor(usage, customAvailable) {
  const list = [];
  if (usage && usage.status === 'ready') {
    const providers = usage.providers || [];
    const hasLocal = providers.some(isLocalApp);
    list.push({ id: 'all', label: hasLocal ? '全部来源' : 'OpenCode · 全部' });
    list.push({ id: 'deepseek', label: 'OpenCode · DeepSeek' });
    for (const provider of providers) {
      if (provider === 'deepseek' || provider === 'opencode') continue;
      if (isLocalApp(provider)) {
        list.push({ id: provider, label: `${providerLabel(provider)} · 本地` });
      } else {
        list.push({ id: provider, label: `OpenCode · ${providerLabel(provider)}` });
      }
    }
  }
  if (customAvailable) list.push({ id: 'custom', label: '自定义 App' });
  return list;
}

function buildState({ usage, custom, settings, now = Date.now(), balance = null, local = null }) {
  const customAvailable = custom != null;
  const sources = sourcesFor(usage, customAvailable);
  const balanceInfo = {
    hasKey: Boolean(balance && balance.hasKey),
    maskedKey: (balance && balance.maskedKey) || '',
    status: (balance && balance.status) || 'idle',
    available: balance ? balance.available : undefined,
    currency: (balance && balance.currency) || 'CNY',
    total: balance && balance.total != null ? balance.total : null,
    granted: balance && balance.granted != null ? balance.granted : null,
    toppedUp: balance && balance.toppedUp != null ? balance.toppedUp : null,
    fetchedAt: (balance && balance.fetchedAt) || null,
    error: (balance && balance.error) || '',
  };
  const localInfo = {
    config: {
      file: (local && local.config && local.config.file) || '',
      url: (local && local.config && local.config.url) || '',
    },
    detections: (local && local.detections) || [],
    errors: (local && local.errors) || [],
    database: (local && local.db) || '',
    collector: (local && local.collector) || { port: null, running: false },
  };
  let source = settings.source || 'all';
  if (!sources.some((item) => item.id === source)) {
    source = sources.length > 0 ? sources[0].id : 'all';
  }
  const period = PERIODS.some((item) => item.id === settings.period) ? settings.period : 'month';
  const tier = settings.tier === 'pro' ? 'pro' : 'flash';
  const showAllRanking = Boolean(settings.showAllRanking);
  const isCustom = source === 'custom';
  const customEmpty = isCustom && Object.keys((custom && custom.all) || {}).length === 0;
  const sourceIsLocal = isLocalApp(source);
  const sourceHasCost = !isCustom && !sourceIsLocal && (source === 'all' || source === 'deepseek');
  const savedAmount = (bucket) => (tier === 'pro' ? bucket.savedPro : bucket.savedFlash);

  const rows = [];
  let selectedTotal = emptyTotals();
  let selectedEntries = [];

  if (isCustom) {
    for (const item of PERIODS) {
      const usageSet = customForPeriod(custom, item.id);
      const total = sumCustom(usageSet);
      rows.push({
        label: item.label,
        money: format.money(total.cost),
        tokens: format.tokens(tokensOf(total)),
        tone: 'cost',
      });
    }
    selectedTotal = sumCustom(customForPeriod(custom, period));
    selectedEntries = entriesOfCustom(customForPeriod(custom, period));
  } else {
    for (const item of PERIODS) {
      const set = setForPeriod(usage, item.id);
      const total = sumBuckets(entriesOfSet(set, source));
      const saved = savedAmount(total);
      rows.push({
        label: item.label,
        money: sourceHasCost ? format.money(total.cost) : saved > 0 ? `省 ${format.money(saved)}` : '—',
        tokens: format.tokens(tokensOf(total)),
        tone: sourceHasCost ? 'cost' : saved > 0 ? 'saved' : 'muted',
      });
    }
    const set = setForPeriod(usage, period);
    selectedEntries = entriesOfSet(set, source);
    selectedTotal = sumBuckets(selectedEntries);
  }

  const selectedSaved = tier === 'pro' ? selectedTotal.savedPro : selectedTotal.savedFlash;

  // 排行
  const entries = selectedEntries.slice(0, showAllRanking ? undefined : 3).map((bucket, index) => {
    let moneyText;
    if (isCustom) {
      moneyText = format.money(bucket.cost);
    } else if (bucket.provider === 'deepseek') {
      moneyText = format.money(bucket.cost);
    } else {
      const saved = savedAmount(bucket);
      moneyText = saved > 0 ? `省 ${format.money(saved)}` : '—';
    }
    return {
      rank: index + 1,
      name: isCustom ? bucket.app : bucket.model,
      sub: source === 'all' && !isCustom ? providerLabel(bucket.provider) : '',
      money: moneyText,
      tokens: format.tokens(tokensOf(bucket)),
    };
  });

  const rate = rateOf(selectedTotal);

  // 近 7 天命中率
  let dailyRaw;
  if (isCustom) {
    dailyRaw = (custom && custom.daily) || [];
  } else {
    dailyRaw = ((usage && usage.daily) || []).filter(
      (item) => item.provider === source || source === 'all',
    );
  }
  const byDay = new Map();
  for (const item of dailyRaw) {
    const key = peak.dayKey(item.date);
    const current = byDay.get(key) || { hit: 0, miss: 0 };
    current.hit += item.hit;
    current.miss += item.miss;
    byDay.set(key, current);
  }
  const daily = [];
  for (let offset = 6; offset >= 0; offset -= 1) {
    const ts = peak.startOfDay(now) - offset * peak.DAY;
    const item = byDay.get(peak.dayKey(ts)) || { hit: 0, miss: 0 };
    const denom = item.hit + item.miss;
    daily.push({
      label: weekdayShort(ts),
      rate: denom > 0 ? item.hit / denom : null,
      isToday: offset === 0,
    });
  }

  const change = peak.nextChange(now);
  const tierInfo = pricing.TIERS[tier];

  const hasLocalProviders = Boolean(usage && (usage.providers || []).some(isLocalApp));
  let note;
  if (isCustom) {
    note = '自定义 App：读取本地 custom-usage.jsonl，用 --report 或脚本写入。';
  } else if (sourceIsLocal) {
    note = `${providerLabel(source)} 用量来自本地日志/代理数据库，只统计 token，不折算费用。`;
  } else if (source === 'all' && hasLocalProviders) {
    note = '费用只统计 DeepSeek；Claude/Codex 等本地 App 只统计 token；Ollama 等本地模型按 DeepSeek 同档价格折算「已省」，仅供参考。';
  } else {
    note = '费用只统计 DeepSeek；Ollama 等本地模型按 DeepSeek 同档价格折算「已省」，仅供参考。';
  }

  return {
    now,
    peak: peak.isPeak(now),
    nextChange: change,
    nextChangeText: change ? peak.targetText(change, now) : '—',
    remainingText: change ? peak.durationText((change - now) / 1000) : '—',
    clockText: peak.timeText(now),
    tier,
    tierName: tierInfo.name,
    modelID: tierInfo.modelID,
    tiers: Object.values(pricing.TIERS).map((item) => ({ id: item.id, name: item.name })),
    price: {
      off: pricing.price(tier, false),
      peak: pricing.price(tier, true),
    },
    pricing: {
      updatedAt: pricing.getState().updatedAt,
      updating: pricing.getState().updating,
      failed: pricing.getState().updateFailed,
    },
    source,
    period,
    sources,
    periods: PERIODS,
    showAllRanking,
    rows,
    hasCost: sourceHasCost,
    showSaved: !isCustom && sourceHasCost && selectedSaved > 0,
    savedText: format.money(savedAmount(selectedTotal)),
    savedTier: tierInfo.name,
    entries,
    entryCount: selectedEntries.length,
    hitRate: rate,
    hitRateText: format.percent(rate),
    advice: adviceText(rate, sourceIsLocal),
    daily,
    usageStatus: isCustom ? 'ready' : (usage && usage.status) || 'failed',
    customEmpty,
    usageError: usage && usage.error,
    note,
    balance: balanceInfo,
    local: localInfo,
    database: usage && usage.database,
    customFile: customLib.file(),
  };
}

module.exports = { buildState, PERIODS, providerLabel };
