'use strict';

const API_URL = 'https://api.deepseek.com/user/balance';
const TIMEOUT = 15000;

function toNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function normalizeInfo(info) {
  if (!info || typeof info !== 'object') return null;
  const currency = typeof info.currency === 'string' && info.currency ? info.currency : 'CNY';
  return {
    currency,
    total: toNumber(info.total_balance),
    granted: toNumber(info.granted_balance),
    toppedUp: toNumber(info.topped_up_balance),
  };
}

function normalize(data) {
  const list = Array.isArray(data && data.balance_infos)
    ? data.balance_infos.map(normalizeInfo).filter(Boolean)
    : [];
  if (list.length === 0) return null;
  const primary = list.find((item) => item.currency === 'CNY') || list[0];
  return {
    available: data.is_available !== false,
    currency: primary.currency,
    total: primary.total,
    granted: primary.granted,
    toppedUp: primary.toppedUp,
    infos: list,
  };
}

async function fetchBalance(apiKey, now = Date.now()) {
  if (!apiKey) return { status: 'idle' };
  try {
    const response = await fetch(API_URL, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        Accept: 'application/json',
      },
      signal: AbortSignal.timeout(TIMEOUT),
    });
    if (response.status === 401 || response.status === 403) {
      return { status: 'error', error: 'API Key 无效或已失效', fetchedAt: now };
    }
    if (response.status === 429) {
      return { status: 'error', error: '请求过于频繁，请稍后再试', fetchedAt: now };
    }
    if (!response.ok) {
      return { status: 'error', error: `官方接口返回 HTTP ${response.status}`, fetchedAt: now };
    }
    const data = await response.json();
    const result = normalize(data);
    if (!result) {
      return { status: 'error', error: '官方接口未返回余额信息', fetchedAt: now };
    }
    return { status: 'ready', ...result, fetchedAt: now };
  } catch (error) {
    const timedOut = error && (error.name === 'TimeoutError' || error.name === 'AbortError');
    return {
      status: 'error',
      error: timedOut ? '请求超时' : `网络请求失败：${error.message || '未知错误'}`,
      fetchedAt: now,
    };
  }
}

module.exports = { fetchBalance, normalize, API_URL };
