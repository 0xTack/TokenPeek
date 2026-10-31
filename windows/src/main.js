'use strict';

const {
  app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen, shell, dialog,
} = require('electron');
const fs = require('fs');
const path = require('path');
const peak = require('./lib/peak');
const pricing = require('./lib/pricing');
const balanceLib = require('./lib/balance');
const usageLib = require('./lib/usage');
const customLib = require('./lib/custom');
const localusage = require('./lib/localusage');
const { startCollector } = require('./lib/collector');
const paths = require('./lib/paths');
const format = require('./lib/format');
const { buildState, providerLabel } = require('./lib/state');

const APP_NAME = 'DeepSeek 仪表盘';
const WIDTH = 396;
const PRICING_URL = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing/';

let tray = null;
let win = null;
let quitting = false;
let settings = {
  tier: 'flash',
  source: 'all',
  period: 'month',
  showAllRanking: false,
};
let usageResult = { status: 'loading' };
let customSnapshot = null;
let lastDataLoad = 0;
let loadingData = false;
let lastPeak = null;
let lastBlurHide = 0;
let apiKey = '';
let balanceResult = { status: 'idle' };
let balanceFetching = false;
const BALANCE_MAX_AGE = 60 * 1000;
let localInfo = { detections: [], errors: [], config: { file: '', url: '' }, db: null };
let collectorState = { port: null, running: false };
let collectorHandle = null;

const hasArg = (name) => process.argv.includes(name);

function logLine(text) {
  try {
    process.stdout.write(`${text}\n`);
  } catch {
    // 打包后的 GUI 程序没有控制台
  }
}

function writeReportFile(name, text) {
  try {
    paths.ensureDir(paths.dataDir());
    fs.writeFileSync(path.join(paths.dataDir(), name), `${text}\n`, 'utf8');
  } catch {
    // 忽略写入失败
  }
}

function loadSettings() {
  try {
    const raw = fs.readFileSync(paths.settingsFile(), 'utf8');
    const parsed = JSON.parse(raw);
    settings = {
      tier: parsed.tier === 'pro' ? 'pro' : 'flash',
      source: typeof parsed.source === 'string' ? parsed.source : 'all',
      period: ['today', 'week', 'month', 'all'].includes(parsed.period) ? parsed.period : 'month',
      showAllRanking: Boolean(parsed.showAllRanking),
    };
  } catch {
    // 首次运行使用默认值
  }
}

function saveSettings() {
  try {
    paths.ensureDir(paths.dataDir());
    fs.writeFileSync(paths.settingsFile(), JSON.stringify(settings, null, 2), 'utf8');
  } catch {
    // 忽略
  }
}

function loadApiKey() {
  try {
    apiKey = fs.readFileSync(paths.apiKeyFile(), 'utf8').trim();
  } catch {
    apiKey = '';
  }
}

function saveApiKey(value) {
  try {
    paths.ensureDir(paths.dataDir());
    if (value) fs.writeFileSync(paths.apiKeyFile(), value, 'utf8');
    else if (fs.existsSync(paths.apiKeyFile())) fs.unlinkSync(paths.apiKeyFile());
  } catch {
    // 无法保存时只在本次运行内生效
  }
}

function maskKey(key) {
  if (!key) return '';
  if (key.length <= 8) return `${key.slice(0, 2)}****`;
  return `${key.slice(0, 3)}****${key.slice(-4)}`;
}

function balanceView() {
  return {
    ...balanceResult,
    hasKey: Boolean(apiKey),
    maskedKey: maskKey(apiKey),
  };
}

async function refreshBalance(force = false) {
  if (!apiKey) {
    balanceResult = { status: 'idle' };
    sendState();
    return balanceResult;
  }
  if (balanceFetching) return balanceResult;
  if (
    !force
    && balanceResult.status === 'ready'
    && Date.now() - (balanceResult.fetchedAt || 0) < BALANCE_MAX_AGE
  ) {
    return balanceResult;
  }
  balanceFetching = true;
  const carry = balanceResult.status === 'ready'
    ? { total: balanceResult.total, currency: balanceResult.currency, granted: balanceResult.granted, toppedUp: balanceResult.toppedUp, fetchedAt: balanceResult.fetchedAt }
    : {};
  balanceResult = { status: 'loading', ...carry };
  sendState();
  try {
    balanceResult = await balanceLib.fetchBalance(apiKey);
  } catch (error) {
    balanceResult = { status: 'error', error: error.message || '查询失败' };
  } finally {
    balanceFetching = false;
  }
  sendState();
  return balanceResult;
}

function currentState(now = Date.now()) {
  return buildState({
    usage: usageResult,
    custom: customSnapshot,
    settings,
    now,
    balance: balanceView(),
    local: { ...localInfo, collector: collectorState },
  });
}

function sendState() {
  if (!win || win.isDestroyed()) return;
  try {
    win.webContents.send('ds:state', currentState());
  } catch {
    // 窗口还没加载完
  }
}

async function refreshData(force = false) {
  if (loadingData) return;
  if (!force && Date.now() - lastDataLoad < 20000) return;
  loadingData = true;
  try {
    const local = await localusage.load();
    localInfo = {
      detections: local.detections,
      errors: local.errors,
      config: local.config,
      db: local.db,
    };
    const usage = await usageLib.load(Date.now(), local.records);
    usageResult = usage;
    customSnapshot = customLib.load();
    lastDataLoad = Date.now();
  } finally {
    loadingData = false;
  }
  updateTray();
  sendState();
}

function trayIcon(peakNow) {
  const name = peakNow ? 'tray-peak.png' : 'tray-idle.png';
  const candidates = [
    path.join(process.resourcesPath || '', name),
    path.join(__dirname, '..', 'assets', name),
  ];
  for (const file of candidates) {
    if (fs.existsSync(file)) return nativeImage.createFromPath(file);
  }
  return nativeImage.createEmpty();
}

function updateTray() {
  if (!tray) return;
  const state = currentState();
  if (state.peak !== lastPeak) {
    lastPeak = state.peak;
    tray.setImage(trayIcon(state.peak));
  }
  const label = state.peak ? '高峰' : '空闲';
  tray.setToolTip(`${APP_NAME} · ${label}${state.nextChange ? ` · 距切换 ${state.remainingText}` : ''}`);
}

function positionWindow() {
  if (!win) return;
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const area = display.workArea;
  const [width, height] = win.getSize();
  let x = Math.round(cursor.x - width / 2);
  x = Math.min(Math.max(x, area.x + 8), area.x + area.width - width - 8);
  const y = cursor.y > area.y + area.height / 2
    ? area.y + area.height - height - 8
    : area.y + 8;
  win.setPosition(x, Math.round(y), false);
}

function createWindow() {
  win = new BrowserWindow({
    width: WIDTH,
    height: 620,
    show: false,
    frame: false,
    resizable: true,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    backgroundColor: '#f5f5f7',
    title: APP_NAME,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  // 允许程序调整高度，但禁止用户拖拽边缘改变大小
  win.on('will-resize', (event) => event.preventDefault());

  win.on('blur', () => {
    if (!quitting && !win.webContents.isDevToolsOpened()) {
      lastBlurHide = Date.now();
      win.hide();
    }
  });
  win.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      win.hide();
    }
  });
  win.webContents.on('did-finish-load', () => {
    sendState();
    if (hasArg('--show')) win.show();
  });
}

function showWindow() {
  if (!win || win.isDestroyed()) createWindow();
  positionWindow();
  win.show();
  win.focus();
  if (Date.now() - lastDataLoad > 20000) refreshData(false);
  else sendState();
  if (apiKey && Date.now() - (balanceResult.fetchedAt || 0) > BALANCE_MAX_AGE) {
    refreshBalance(false);
  }
}

function toggleWindow() {
  if (win && win.isVisible()) {
    win.hide();
  } else {
    // 点托盘关闭时，blur 会先把窗口隐藏；此时不要再立刻显示
    if (Date.now() - lastBlurHide < 250) return;
    showWindow();
  }
}

function openPricing() {
  shell.openExternal(PRICING_URL);
}

function openDataFolder() {
  paths.ensureDir(paths.dataDir());
  shell.openPath(paths.dataDir());
}

function startupEnabled() {
  try {
    return app.getLoginItemSettings().openAtLogin;
  } catch {
    return false;
  }
}

function toggleStartup() {
  try {
    const next = !startupEnabled();
    app.setLoginItemSettings({ openAtLogin: next, args: ['--background'] });
  } catch {
    // 开发模式下可能不支持
  }
}

function buildMenu() {
  return Menu.buildFromTemplate([
    { label: '打开面板', click: () => showWindow() },
    { label: '刷新用量', click: () => refreshData(true) },
    { label: '刷新官方余额', visible: Boolean(apiKey), click: () => refreshBalance(true) },
    { type: 'separator' },
    { label: '开机自动启动', type: 'checkbox', checked: startupEnabled(), click: () => toggleStartup() },
    { label: '价格来源', click: openPricing },
    { label: '打开数据文件夹', click: openDataFolder },
    { type: 'separator' },
    { label: '退出', click: () => { quitting = true; app.quit(); } },
  ]);
}

function createTray() {
  tray = new Tray(trayIcon(peak.isPeak()));
  tray.setToolTip(APP_NAME);
  tray.on('click', () => toggleWindow());
  tray.on('right-click', () => tray.popUpContextMenu(buildMenu()));
  tray.on('double-click', () => showWindow());
}

function printUsageSet(title, set) {
  const list = Object.values(set || {});
  const total = list.reduce(
    (acc, item) => {
      acc.hit += item.hit;
      acc.miss += item.miss;
      acc.output += item.output;
      acc.cost += item.cost;
      acc.savedFlash += item.savedFlash;
      acc.savedPro += item.savedPro;
      return acc;
    },
    { hit: 0, miss: 0, output: 0, cost: 0, savedFlash: 0, savedPro: 0 },
  );
  const denom = total.hit + total.miss;
  const rate = denom > 0 ? `${((total.hit / denom) * 100).toFixed(1)}%` : '—';
  const line = `${title}：全部 ${format.money(total.cost)} · ${format.tokens(total.hit + total.miss + total.output)} tokens · 命中率 ${rate}`;
  logLine(line);
  if (total.savedFlash > 0 || total.savedPro > 0) {
    logLine(`  本地模型已省：按 Flash ${format.money(total.savedFlash)} · 按 Pro ${format.money(total.savedPro)}`);
  }
  const ranked = list
    .filter((item) => item.hit + item.miss + item.output > 0 || item.cost > 0)
    .sort((a, b) => (b.hit + b.miss + b.output) - (a.hit + a.miss + a.output))
    .slice(0, 3);
  for (const item of ranked) {
    let money;
    if (item.provider === 'deepseek') money = format.money(item.cost);
    else if (item.savedFlash > 0) money = `省 ${format.money(item.savedFlash)}`;
    else money = '—';
    logLine(`  ${item.model} [${providerLabel(item.provider)}]  ${money} · ${format.tokens(item.hit + item.miss + item.output)} tokens`);
  }
  return line;
}

function printUsageResult(result) {
  const lines = [];
  if (result.status === 'ready') {
    lines.push(printUsageSet('今日', result.today));
    lines.push(printUsageSet('近 7 天', result.week));
    lines.push(printUsageSet('本月', result.month));
    lines.push(printUsageSet('全部', result.allTime));
  } else if (result.status === 'unavailable') {
    lines.push('未找到 OpenCode 用量数据库');
  } else {
    lines.push(`读取用量失败：${result.error || ''}`);
  }
  writeReportFile('last-usage.txt', lines.join('\n'));
  logLine(`（已写入 ${path.join(paths.dataDir(), 'last-usage.txt')}）`);
}

function runSelfTest() {
  const cases = [
    ['2026-10-30 10:00', true],
    ['2026-10-30 12:00', false],
    ['2026-10-30 14:30', true],
    ['2026-10-30 18:00', false],
    ['2026-10-31 10:00', false],
    ['2026-10-01 10:00', false],
    ['2026-11-02 09:00', true],
    ['2026-11-02 08:59', false],
  ];
  const lines = [];
  let failed = 0;
  for (const [text, expected] of cases) {
    const date = peak.parseBeijing(text);
    const actual = peak.isPeak(date);
    if (actual !== expected) failed += 1;
    lines.push(`${text} 期望 ${expected ? '高峰' : '空闲'} 实际 ${actual ? '高峰' : '空闲'}`);
  }
  lines.push(failed === 0 ? '全部通过' : `失败 ${failed} 项`);
  writeReportFile('last-self-test.txt', lines.join('\n'));
  for (const line of lines) logLine(line);
  return failed === 0;
}

function runCheck() {
  pricing.loadCache();
  const now = Date.now();
  const isPeak = peak.isPeak(now);
  const lines = [
    `当前：${isPeak ? '高峰时段' : '空闲时段'}`,
    `北京时间：${peak.timeText(now)}`,
    `Flash 百万未命中输入费用：${format.money(pricing.cost('flash', isPeak, 0, 1000000, 0))}`,
  ];
  for (const line of lines) logLine(line);
  writeReportFile('last-check.txt', lines.join('\n'));
}

function registerIpc() {
  ipcMain.handle('ds:get-state', () => currentState());

  ipcMain.handle('ds:action', async (_event, message) => {
    const { type, payload } = message || {};
    switch (type) {
      case 'refresh':
        await refreshData(true);
        break;
      case 'refresh-pricing':
        await pricing.fetchNow();
        await refreshData(true);
        break;
      case 'refresh-balance':
        await refreshBalance(true);
        break;
      case 'set-api-key': {
        const key = String(payload || '').trim();
        if (!key) break;
        apiKey = key;
        saveApiKey(key);
        await refreshBalance(true);
        break;
      }
      case 'clear-api-key':
        apiKey = '';
        saveApiKey('');
        balanceResult = { status: 'idle' };
        break;
      case 'save-local-source': {
        const next = localusage.saveConfig({
          file: payload && payload.file,
          url: payload && payload.url,
        });
        localInfo = { ...localInfo, config: next, errors: [] };
        await refreshData(true);
        break;
      }
      case 'clear-local-source':
        localusage.saveConfig({ file: '', url: '' });
        localInfo = { ...localInfo, config: { file: '', url: '' }, errors: [] };
        await refreshData(true);
        break;
      case 'set-tier':
        settings.tier = payload === 'pro' ? 'pro' : 'flash';
        break;
      case 'set-source':
        settings.source = String(payload || 'all');
        settings.showAllRanking = false;
        customSnapshot = customLib.load();
        break;
      case 'set-period':
        settings.period = ['today', 'week', 'month', 'all'].includes(payload) ? payload : 'month';
        settings.showAllRanking = false;
        break;
      case 'toggle-ranking':
        settings.showAllRanking = !settings.showAllRanking;
        break;
      case 'quit':
        quitting = true;
        app.quit();
        break;
      case 'open-url':
        if (typeof payload === 'string' && /^https?:\/\//.test(payload)) shell.openExternal(payload);
        break;
      case 'hide':
        if (win) win.hide();
        break;
      case 'open-data-folder':
        openDataFolder();
        break;
      case 'toggle-startup':
        toggleStartup();
        break;
      case 'show-about':
        dialog.showMessageBox({
          type: 'info',
          title: APP_NAME,
          message: `${APP_NAME} 1.3（Windows）`,
          detail: 'DeepSeek 时段、本地与第三方 App 用量、官方余额统计。\n数据只保存在本机，不上传。',
          buttons: ['好'],
        });
        break;
      default:
        break;
    }
    saveSettings();
    updateTray();
    const state = currentState();
    if (win && !win.isDestroyed()) win.webContents.send('ds:state', state);
    return state;
  });

  ipcMain.on('ds:resize', (_event, rawHeight) => {
    if (!win || win.isDestroyed()) return;
    const height = Math.round(Number(rawHeight));
    if (!Number.isFinite(height)) return;
    const cursor = screen.getCursorScreenPoint();
    const display = screen.getDisplayNearestPoint(cursor);
    const maxHeight = display.workArea.height - 16;
    const next = Math.max(260, Math.min(height, maxHeight));
    const [width, current] = win.getSize();
    if (current !== next) {
      win.setContentSize(width, next, false);
      if (win.isVisible()) positionWindow();
    }
  });
}

// CLI 模式：不启动托盘
if (hasArg('--report')) {
  const result = customLib.report(process.argv);
  logLine(result.message);
  writeReportFile('last-report.txt', result.message);
  process.exit(result.ok ? 0 : 1);
}

if (hasArg('--usage')) {
  pricing.loadCache();
  const local = localusage.loadSync();
  printUsageResult(usageLib.loadSync(Date.now(), local.records));
  process.exit(0);
}

if (hasArg('--self-test')) {
  process.exit(runSelfTest() ? 0 : 1);
}

if (hasArg('--check')) {
  runCheck();
  process.exit(0);
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow());

  app.whenReady().then(async () => {
    app.setAppUserModelId('local.deepseekcost');
    if (process.platform === 'darwin') app.dock.hide();

    loadSettings();
    loadApiKey();
    pricing.loadCache();
    const pricingRefresh = pricing.refreshIfNeeded();

    registerIpc();
    createTray();
    createWindow();
    await refreshData(true);
    updateTray();
    refreshBalance(true);
    startCollector({ onRecord: () => refreshData(true) }).then((result) => {
      collectorHandle = result;
      collectorState = {
        port: result.port,
        running: Boolean(result.port),
        error: result.error || '',
      };
      sendState();
    });
    pricingRefresh.then((result) => {
      if (result && result.ok) refreshData(true);
    });

    if (hasArg('--show')) {
      setTimeout(() => showWindow(), 600);
    }

    setInterval(() => {
      if (win && win.isVisible()) sendState();
    }, 1000);

    setInterval(() => {
      updateTray();
      if (win && win.isVisible() && Date.now() - lastDataLoad > 60000) refreshData(false);
    }, 30000);

  });

  app.on('window-all-closed', () => {
    // 托盘常驻，不退出
  });

  app.on('before-quit', () => {
    quitting = true;
    if (collectorHandle && typeof collectorHandle.close === 'function') collectorHandle.close();
  });
}
