'use strict';

const $ = (id) => document.getElementById(id);
const PRICING_URL = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing/';

let state = null;
let lastSignature = '';
let lastSentHeight = 0;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function money(value) {
  return `¥${Number(value || 0).toFixed(2)}`;
}

function currencySymbol(code) {
  if (code === 'USD') return '$';
  if (code === 'CNY' || !code) return '¥';
  return `${code} `;
}

function balanceMoney(value, code) {
  return `${currencySymbol(code)}${Number(value || 0).toFixed(2)}`;
}

function clockTime(timestamp) {
  const date = new Date(timestamp);
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

function signature(s) {
  return JSON.stringify([
    s.tier,
    s.source,
    s.period,
    s.showAllRanking,
    s.rows,
    s.entries,
    s.entryCount,
    s.hitRate,
    s.hitRateText,
    s.daily,
    s.usageStatus,
    s.usageError,
    s.note,
    s.showSaved,
    s.customEmpty,
    s.savedText,
    s.savedTier,
    s.sources,
    s.price,
    s.pricing,
    s.balance,
    s.local,
  ]);
}

function periodLabel(s, id) {
  const item = (s.periods || []).find((p) => p.id === id);
  return item ? item.label : id;
}

function renderHeader(s) {
  const dot = $('status-dot');
  dot.classList.toggle('peak', s.peak);
  $('status-title').textContent = s.peak ? '高峰时段' : '空闲时段';
  const badge = $('status-badge');
  badge.textContent = s.peak ? '标准价' : '5 折';
  badge.classList.toggle('peak', s.peak);
  if (s.nextChange) {
    const next = s.peak ? '空闲' : '高峰';
    $('countdown').textContent = `距离 ${next} ${s.nextChangeText} · ${s.remainingText}`;
  } else {
    $('countdown').textContent = `北京时间 ${s.clockText}`;
  }
}

function renderPrice(s) {
  $('price-hit-off').textContent = money(s.price.off.hit);
  $('price-hit-peak').textContent = money(s.price.peak.hit);
  $('price-miss-off').textContent = money(s.price.off.miss);
  $('price-miss-peak').textContent = money(s.price.peak.miss);
  $('price-output-off').textContent = money(s.price.off.output);
  $('price-output-peak').textContent = money(s.price.peak.output);

  $('price-model').textContent = `${s.modelID} · 人民币`;
  let updated;
  if (s.pricing.updating) updated = '更新中…';
  else if (s.pricing.failed) updated = '更新失败';
  else if (s.pricing.updatedAt) {
    const d = new Date(s.pricing.updatedAt + 8 * 3600 * 1000);
    updated = `价格 ${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
  } else updated = '内置价格';
  $('price-updated').textContent = updated;
}

function renderBalance(s) {
  const b = s.balance || {};
  const body = $('balance-body');
  clear(body);
  $('balance-refresh').classList.toggle('hidden', !b.hasKey);
  $('balance-tag').classList.toggle('hidden', !b.hasKey);

  if (!b.hasKey) {
    const form = el('div', 'balance-form');
    const input = el('input', 'key-input');
    input.type = 'password';
    input.placeholder = 'sk-...（仅存本机）';
    input.autocomplete = 'off';
    input.spellcheck = false;
    const save = el('button', 'primary-button', '绑定');
    const submit = () => {
      const value = input.value.trim();
      if (!value) {
        input.focus();
        return;
      }
      save.disabled = true;
      save.textContent = '绑定中…';
      window.ds.action('set-api-key', value);
    };
    save.addEventListener('click', submit);
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') submit();
    });
    form.appendChild(input);
    form.appendChild(save);
    body.appendChild(form);
    body.appendChild(
      el('div', 'balance-note', '绑定 DeepSeek API Key 后查询官方账户余额。Key 只保存在本机，不会上传。'),
    );
    return;
  }

  const line = el('div', 'balance-head');
  if (b.status === 'loading') {
    line.appendChild(el('span', 'spinner'));
    line.appendChild(el('span', 'balance-note', '查询官方余额中…'));
  } else if (b.status === 'ready') {
    line.appendChild(el('span', 'balance-total', balanceMoney(b.total, b.currency)));
    line.appendChild(
      el(
        'span',
        'balance-sub',
        `充值 ${balanceMoney(b.toppedUp, b.currency)} · 赠送 ${balanceMoney(b.granted, b.currency)}`,
      ),
    );
  } else {
    const text = b.status === 'error' ? `查询失败：${b.error || '未知错误'}` : '尚未查询';
    line.appendChild(el('span', 'balance-error', text));
  }
  body.appendChild(line);

  if (b.status === 'ready' && b.available === false) {
    body.appendChild(el('div', 'balance-note', '官方账户当前不可用（余额不足或被限制）。'));
  }

  const meta = el('div', 'balance-meta');
  meta.appendChild(el('span', '', b.maskedKey));
  if (b.fetchedAt) meta.appendChild(el('span', '', `更新于 ${clockTime(b.fetchedAt)}`));
  const unbind = el('button', 'link-button', '解绑');
  unbind.addEventListener('click', () => window.ds.action('clear-api-key'));
  meta.appendChild(unbind);
  body.appendChild(meta);
}

function renderTier(s) {
  const box = $('tier');
  clear(box);
  for (const tier of s.tiers) {
    const button = el('button', tier.id === s.tier ? 'active' : '', tier.name);
    button.addEventListener('click', () => window.ds.action('set-tier', tier.id));
    box.appendChild(button);
  }
}

function renderMenu(menu, items, selected, actionType) {
  clear(menu);
  for (const item of items) {
    const option = el(
      'button',
      `select-option${item.id === selected ? ' active' : ''}`,
      item.label,
    );
    option.type = 'button';
    option.title = item.label;
    option.addEventListener('click', (event) => {
      event.stopPropagation();
      closeMenus();
      window.ds.action(actionType, item.id);
    });
    menu.appendChild(option);
  }
}

function closeMenus() {
  $('source-menu').classList.add('hidden');
  $('period-menu').classList.add('hidden');
}

function toggleMenu(id) {
  const menu = $(id);
  const wasHidden = menu.classList.contains('hidden');
  closeMenus();
  if (wasHidden) menu.classList.remove('hidden');
}

function renderSelects(s) {
  const sources = s.sources || [];
  const periods = s.periods || [];
  const sourceItem = sources.find((item) => item.id === s.source);
  const periodItem = periods.find((item) => item.id === s.period);

  $('source').textContent = sourceItem ? sourceItem.label : s.source;
  $('source').title = sourceItem ? sourceItem.label : '';
  $('period').textContent = periodItem ? periodItem.label : s.period;
  $('period').title = periodItem ? periodItem.label : '';

  renderMenu($('source-menu'), sources, s.source, 'set-source');
  renderMenu($('period-menu'), periods, s.period, 'set-period');
}

function buildRow(item) {
  const row = el('div', 'usage-row');
  row.appendChild(el('span', 'label', item.label));
  const moneyNode = el('span', `money ${item.tone === 'saved' ? 'saved' : item.tone === 'muted' ? 'muted' : ''}`, item.money);
  row.appendChild(moneyNode);
  row.appendChild(el('span', 'tokens', `${item.tokens} tokens`));
  return row;
}

function buildEntry(item, isCustom) {
  const row = el('div', 'entry');
  row.appendChild(el('span', `rank${item.rank === 1 ? ' first' : ''}`, String(item.rank)));
  row.appendChild(el('span', 'name', item.name));
  if (item.sub) row.appendChild(el('span', 'provider', `· ${item.sub}`));
  row.appendChild(el('span', 'money', item.money));
  row.appendChild(el('span', 'tokens', item.tokens));
  return row;
}

function rateClass(rate) {
  if (rate == null) return 'none';
  return rate >= 0.5 ? 'good' : 'bad';
}

function buildRateBlock(s) {
  const wrap = el('div', '');
  wrap.appendChild(el('div', 'divider'));
  const head = el('div', 'rate-head');
  head.appendChild(el('span', 'label', '缓存命中率'));
  const value = el('span', `value ${rateClass(s.hitRate)}`, s.hitRateText);
  head.appendChild(value);
  wrap.appendChild(head);

  const bar = el('div', 'rate-bar');
  const fill = el('div', s.hitRate != null && s.hitRate < 0.5 ? 'bad' : '');
  fill.style.width = `${Math.max(0, Math.min(1, s.hitRate == null ? 0 : s.hitRate)) * 100}%`;
  bar.appendChild(fill);
  wrap.appendChild(bar);

  wrap.appendChild(el('div', 'advice', s.advice));

  const daily = el('div', 'daily');
  for (const day of s.daily) {
    const column = el('div', 'day');
    column.appendChild(el('span', 'pct', day.rate == null ? '—' : `${Math.round(day.rate * 100)}%`));
    const barWrap = el('div', 'bar-wrap');
    const bar = el(
      'div',
      `bar${day.rate == null ? ' empty' : day.rate < 0.5 ? ' bad' : ''}`,
    );
    bar.style.height = `${day.rate == null ? 3 : Math.max(3, 30 * day.rate)}px`;
    barWrap.appendChild(bar);
    column.appendChild(barWrap);
    column.appendChild(el('span', `name${day.isToday ? ' today' : ''}`, day.label));
    daily.appendChild(column);
  }
  wrap.appendChild(daily);
  return wrap;
}

function renderUsage(s) {
  const body = $('usage-body');
  clear(body);

  if (s.usageStatus === 'loading') {
    const loading = el('div', 'loading');
    loading.appendChild(el('span', 'spinner'));
    loading.appendChild(el('span', '', '读取中…'));
    body.appendChild(loading);
    return;
  }

  if (s.usageStatus === 'unavailable') {
    body.appendChild(el('div', 'empty', '未找到本机 OpenCode 用量记录'));
    body.appendChild(el('div', 'empty', '安装 OpenCode 并产生用量后，这里会自动显示。'));
    return;
  }

  if (s.usageStatus === 'failed') {
    body.appendChild(el('div', 'empty', '读取失败，可点右上角刷新'));
    if (s.usageError) body.appendChild(el('div', 'empty', s.usageError));
    return;
  }

  if (s.customEmpty) {
    body.appendChild(el('div', 'empty', '还没有自定义 App 用量'));
    body.appendChild(el('div', 'empty', '用 --report 上报，或写入 custom-usage.jsonl。'));
    return;
  }

  for (const item of s.rows) body.appendChild(buildRow(item));

  if (s.showSaved) {
    const saved = el('div', 'saved-line');
    saved.appendChild(el('span', '', '本地模型已省'));
    saved.appendChild(el('span', 'amount', s.savedText));
    saved.appendChild(el('span', 'hint', `按 ${s.savedTier} 价`));
    body.appendChild(saved);
  }

  const entriesTitle = `${s.source === 'custom' ? 'App 用量' : 'API 用量'} · ${periodLabel(s, s.period)}`;
  body.appendChild(el('div', 'subhead', entriesTitle));

  if (s.entries.length === 0) {
    body.appendChild(
      el('div', 'empty', s.source === 'custom' ? '该时段没有自定义用量' : '该时段还没有用量'),
    );
  } else {
    for (const item of s.entries) body.appendChild(buildEntry(item));
    if (s.entryCount > 3) {
      const toggle = el(
        'button',
        'toggle',
        s.showAllRanking ? '收起' : `展开全部 ${s.entryCount} 个`,
      );
      toggle.addEventListener('click', () => window.ds.action('toggle-ranking'));
      body.appendChild(toggle);
    }
  }

  body.appendChild(buildRateBlock(s));
}

function renderNote(s) {
  $('note').textContent = s.note;
}

function renderLocalInfo(s) {
  const local = (s && s.local) || {};
  const status = $('local-status');
  const errors = local.errors || [];
  const hasTarget = Boolean((local.config && local.config.file) || (local.config && local.config.url));
  status.textContent = errors.length > 0
    ? errors.join('；')
    : hasTarget
      ? '已保存，检测结果如下'
      : '自动发现始终开启；也可以手动指定本地文件或内网地址';
  status.classList.toggle('bad', errors.length > 0);

  const list = $('local-detections');
  clear(list);
  for (const item of local.detections || []) {
    const row = el('div', 'config-item');
    row.appendChild(el('span', 'config-item-name', item.label));
    row.appendChild(el('span', 'config-item-value', item.available ? `${item.count} 条` : '未发现'));
    list.appendChild(row);
    if (item.detail) list.appendChild(el('div', 'config-item-detail', item.detail));
  }

  const collector = $('local-collector');
  if (local.collector && local.collector.running) {
    collector.textContent = `收集接口：http://127.0.0.1:${local.collector.port}/usage`;
  } else {
    const suffix = local.collector && local.collector.error ? `：${local.collector.error}` : '';
    collector.textContent = `收集接口未启动${suffix}`;
  }
}

function openLocalPanel(s) {
  const local = (s && s.local) || {};
  const config = local.config || {};
  $('local-file').value = config.file || '';
  $('local-url').value = config.url || '';
  renderLocalInfo(s);
  $('local-modal').classList.remove('hidden');
}

function hideLocalPanel() {
  $('local-modal').classList.add('hidden');
}

function resize() {
  const app = $('app');
  if (!app) return;
  const height = Math.ceil(app.getBoundingClientRect().height);
  if (height > 0 && Math.abs(height - lastSentHeight) > 1) {
    lastSentHeight = height;
    window.ds.resize(height);
  }
}

function apply(next) {
  if (!next) return;
  state = next;
  renderHeader(state);
  renderPrice(state);
  renderNote(state);
  renderLocalInfo(state);

  const sig = signature(state);
  if (sig !== lastSignature) {
    lastSignature = sig;
    renderTier(state);
    renderSelects(state);
    renderBalance(state);
    renderUsage(state);
  }
  resize();
}

function wire() {
  $('close').addEventListener('click', () => window.ds.action('hide'));
  $('refresh').addEventListener('click', () => window.ds.action('refresh'));
  $('price-refresh').addEventListener('click', () => window.ds.action('refresh-pricing'));
  $('balance-refresh').addEventListener('click', () => window.ds.action('refresh-balance'));
  $('open-folder').addEventListener('click', () => window.ds.action('open-data-folder'));
  $('local-open').addEventListener('click', () => openLocalPanel(state));
  $('local-close').addEventListener('click', () => hideLocalPanel());
  $('local-modal').addEventListener('click', (event) => {
    if (event.target === $('local-modal')) hideLocalPanel();
  });
  $('local-save').addEventListener('click', async () => {
    const button = $('local-save');
    button.disabled = true;
    button.textContent = '检测中…';
    try {
      const next = await window.ds.action('save-local-source', {
        file: $('local-file').value,
        url: $('local-url').value,
      });
      if (next) apply(next);
    } finally {
      button.disabled = false;
      button.textContent = '保存并检测';
    }
  });
  $('local-clear').addEventListener('click', async () => {
    $('local-file').value = '';
    $('local-url').value = '';
    const next = await window.ds.action('clear-local-source');
    if (next) apply(next);
  });
  $('price-link').addEventListener('click', () => window.ds.action('open-url', PRICING_URL));
  $('quit').addEventListener('click', () => window.ds.action('quit'));

  $('source').addEventListener('click', (event) => {
    event.stopPropagation();
    toggleMenu('source-menu');
  });
  $('period').addEventListener('click', (event) => {
    event.stopPropagation();
    toggleMenu('period-menu');
  });
  document.addEventListener('click', closeMenus);

  $('support').addEventListener('click', () => {
    $('donation-modal').classList.remove('hidden');
  });
  $('donation-modal').addEventListener('click', () => {
    $('donation-modal').classList.add('hidden');
  });

  // 开源构建可能不包含赞赏码；没有图片时隐藏整个入口
  const donationImage = document.querySelector('#donation-modal img');
  const donationSection = document.querySelector('.donation');
  if (donationImage && donationSection) {
    const hideDonation = () => {
      donationSection.classList.add('hidden');
      $('donation-modal').classList.add('hidden');
    };
    donationImage.addEventListener('error', hideDonation);
    if (donationImage.complete && donationImage.naturalWidth === 0) hideDonation();
  }

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      const menuOpen = !$('source-menu').classList.contains('hidden')
        || !$('period-menu').classList.contains('hidden');
      if (menuOpen) {
        closeMenus();
        return;
      }
      const localModal = $('local-modal');
      if (!localModal.classList.contains('hidden')) {
        hideLocalPanel();
        return;
      }
      const modal = $('donation-modal');
      if (!modal.classList.contains('hidden')) {
        modal.classList.add('hidden');
        return;
      }
      window.ds.action('hide');
    }
  });

  const observer = new ResizeObserver(() => resize());
  observer.observe($('app'));
}

async function init() {
  wire();
  apply(await window.ds.getState());
  window.ds.onState(apply);
}

init().catch((error) => {
  $('countdown').textContent = `启动失败：${error.message}`;
});
