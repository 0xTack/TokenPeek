'use strict';

function tokens(value) {
  const v = Number(value) || 0;
  if (v <= 0) return '0';
  if (v >= 100000000) return `${(v / 100000000).toFixed(2)} 亿`;
  if (v >= 10000) return `${(v / 10000).toFixed(1)} 万`;
  return v.toLocaleString('zh-CN');
}

function money(value, digits) {
  const v = Math.max(0, Number(value) || 0);
  const d = digits != null ? digits : v === 0 ? 2 : v >= 1 ? 2 : v >= 0.01 ? 4 : 6;
  return `¥${v.toFixed(d)}`;
}

function percent(rate) {
  if (rate == null || !Number.isFinite(rate)) return '—';
  return `${(rate * 100).toFixed(1)}%`;
}

module.exports = { tokens, money, percent };
