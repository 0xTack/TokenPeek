'use strict';

// 北京时间没有夏令时，直接按 UTC+8 计算，避免依赖系统时区。
const BEIJING_OFFSET = 8 * 60 * 60 * 1000;
const DAY = 24 * 60 * 60 * 1000;

// 中国法定节假日（2025–2026，北京时间自然日）
const HOLIDAY_RANGES = [
  ['2025-01-01', '2025-01-01'],
  ['2025-01-28', '2025-02-04'],
  ['2025-04-04', '2025-04-06'],
  ['2025-05-01', '2025-05-05'],
  ['2025-05-31', '2025-06-02'],
  ['2025-10-01', '2025-10-08'],
  ['2026-01-01', '2026-01-03'],
  ['2026-02-15', '2026-02-23'],
  ['2026-04-04', '2026-04-06'],
  ['2026-05-01', '2026-05-05'],
  ['2026-06-19', '2026-06-21'],
  ['2026-09-25', '2026-09-27'],
  ['2026-10-01', '2026-10-07'],
];

function pad2(value) {
  return String(value).padStart(2, '0');
}

function parts(timestamp = Date.now()) {
  const d = new Date(timestamp + BEIJING_OFFSET);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    weekday: d.getUTCDay(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    second: d.getUTCSeconds(),
  };
}

function dayKey(timestamp = Date.now()) {
  const p = parts(timestamp);
  return `${p.year}-${pad2(p.month)}-${pad2(p.day)}`;
}

function toBeijing(y, m, d, hh = 0, mm = 0, ss = 0) {
  return Date.UTC(y, m - 1, d, hh, mm, ss) - BEIJING_OFFSET;
}

function parseBeijing(text) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec(text.trim());
  if (!m) return null;
  return toBeijing(+m[1], +m[2], +m[3], +m[4], +m[5], 0);
}

const holidays = (() => {
  const set = new Set();
  for (const [startText, endText] of HOLIDAY_RANGES) {
    const start = parseBeijing(`${startText} 00:00`);
    const end = parseBeijing(`${endText} 00:00`);
    if (start == null || end == null) continue;
    for (let t = start; t <= end; t += DAY) set.add(dayKey(t));
  }
  return set;
})();

function isPeak(timestamp = Date.now()) {
  const p = parts(timestamp);
  if (p.weekday === 0 || p.weekday === 6) return false;
  if (holidays.has(dayKey(timestamp))) return false;
  const minutes = p.hour * 60 + p.minute;
  return (minutes >= 540 && minutes < 720) || (minutes >= 840 && minutes < 1080);
}

function startOfDay(timestamp = Date.now()) {
  return Math.floor((timestamp + BEIJING_OFFSET) / DAY) * DAY - BEIJING_OFFSET;
}

function startOfMonth(timestamp = Date.now()) {
  const p = parts(timestamp);
  return toBeijing(p.year, p.month, 1, 0, 0, 0);
}

function startOfWeek(timestamp = Date.now()) {
  return startOfDay(timestamp) - 6 * DAY;
}

function nextChange(timestamp = Date.now()) {
  const current = isPeak(timestamp);
  const today = startOfDay(timestamp);
  // 时段切换只可能发生在 00:00 / 09:00 / 12:00 / 14:00 / 18:00
  for (let offset = 0; offset < 22; offset += 1) {
    const base = today + offset * DAY;
    for (const hour of [0, 9, 12, 14, 18]) {
      const candidate = base + hour * 60 * 60 * 1000;
      if (candidate > timestamp && isPeak(candidate) !== current) return candidate;
    }
  }
  return null;
}

function timeText(timestamp = Date.now()) {
  const p = parts(timestamp);
  return `${pad2(p.hour)}:${pad2(p.minute)}:${pad2(p.second)}`;
}

function hmText(timestamp) {
  const p = parts(timestamp);
  return `${pad2(p.hour)}:${pad2(p.minute)}`;
}

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function weekdayText(timestamp) {
  return WEEKDAYS[parts(timestamp).weekday];
}

function targetText(target, now = Date.now()) {
  const day = dayKey(target);
  let label;
  if (day === dayKey(now)) label = '今天';
  else if (day === dayKey(now + DAY)) label = '明天';
  else label = weekdayText(target);
  return `${label} ${hmText(target)}`;
}

function durationText(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const d = Math.floor(total / 86400);
  const h = Math.floor((total % 86400) / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (d > 0) return m === 0 ? `${d} 天 ${h} 小时` : `${d} 天 ${h} 小时 ${m} 分`;
  if (h > 0) return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
  if (m > 0) return `${m} 分 ${s} 秒`;
  return `${s} 秒`;
}

function isSameDay(a, b) {
  return dayKey(a) === dayKey(b);
}

module.exports = {
  DAY,
  isPeak,
  nextChange,
  startOfDay,
  startOfWeek,
  startOfMonth,
  dayKey,
  timeText,
  targetText,
  durationText,
  weekdayText,
  isSameDay,
  parseBeijing,
  toBeijing,
  parts,
  holidays,
};
