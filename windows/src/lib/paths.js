'use strict';

const fs = require('fs');
const path = require('path');

function appDataDir(app) {
  const base = process.env.APPDATA
    || path.join(require('os').homedir(), 'AppData', 'Roaming');
  return path.join(base, 'DeepSeekCost');
}

function dataDir(app) {
  // 开发时（macOS）写到单独目录，避免和 macOS 正式版的数据/缓存混在一起
  if (process.platform === 'darwin') {
    return path.join(require('os').homedir(), 'Library', 'Application Support', 'DeepSeekCost-Windows');
  }
  return appDataDir(app);
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function customFile() {
  return path.join(dataDir(), 'custom-usage.jsonl');
}

function pricingFile() {
  return path.join(dataDir(), 'pricing.json');
}

function settingsFile() {
  return path.join(dataDir(), 'settings.json');
}

function tokenFile() {
  return path.join(dataDir(), 'platform-token');
}

function apiKeyFile() {
  return path.join(dataDir(), 'api-key');
}

function localSourceFile() {
  return path.join(dataDir(), 'local-source.json');
}

function localUsageFile() {
  return path.join(dataDir(), 'local-usage.jsonl');
}

function usageDumpFile() {
  return path.join(dataDir(), 'last-usage.txt');
}

function opencodeCandidates() {
  const home = require('os').homedir();
  const localAppData = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
  const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
  const list = [
    path.join(home, '.local', 'share', 'opencode', 'opencode.db'),
    path.join(localAppData, 'opencode', 'opencode.db'),
    path.join(appData, 'opencode', 'opencode.db'),
  ];
  if (process.platform === 'darwin') {
    list.push(path.join(home, '.local', 'share', 'opencode', 'opencode.db'));
    list.push(path.join(home, 'Library', 'Application Support', 'opencode', 'opencode.db'));
  }
  return [...new Set(list)];
}

function opencodeDb() {
  return opencodeCandidates().find((candidate) => fs.existsSync(candidate)) || null;
}

function sqliteBinary() {
  if (process.platform !== 'win32') {
    return ['/usr/bin/sqlite3', '/opt/homebrew/bin/sqlite3'].find((p) => fs.existsSync(p)) || null;
  }
  const packaged = path.join(process.resourcesPath || '', 'sqlite3.exe');
  if (fs.existsSync(packaged)) return packaged;
  const adjacent = path.join(__dirname, '..', '..', 'vendor', 'sqlite3.exe');
  if (fs.existsSync(adjacent)) return adjacent;
  return null;
}

module.exports = {
  appDataDir,
  dataDir,
  ensureDir,
  customFile,
  pricingFile,
  settingsFile,
  tokenFile,
  apiKeyFile,
  localSourceFile,
  localUsageFile,
  usageDumpFile,
  opencodeCandidates,
  opencodeDb,
  sqliteBinary,
};
