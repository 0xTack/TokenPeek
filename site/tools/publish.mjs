#!/usr/bin/env node
/**
 * 更新发布页的数据文件。
 *
 * 示例：
 *   ./publish.sh --version 1.2 --notes "修复 xxx|新增 yyy"
 *   ./publish.sh --version 1.2 --notes-file notes.txt
 *   ./publish.sh --version 1.2 --base "https://github.com/you/repo/releases/download/v1.2/"
 *   ./publish.sh --check
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const SITE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RELEASES_FILE = path.join(SITE_DIR, 'assets', 'releases.js');
const DOWNLOAD_DIR = path.join(SITE_DIR, 'downloads');
const MAC_DIST = path.resolve(SITE_DIR, '..', 'dist');

const args = process.argv.slice(2);
const hasFlag = (name) => args.includes(name);
const option = (name, fallback = null) => {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  return index + 1 < args.length ? args[index + 1] : fallback;
};

function fail(message) {
  console.error(`错误：${message}`);
  process.exit(1);
}

function loadRelease() {
  const code = fs.readFileSync(RELEASES_FILE, 'utf8');
  const sandbox = { window: {} };
  vm.runInNewContext(code, sandbox, { filename: 'releases.js' });
  const data = sandbox.window.DEEPSEEK_RELEASE;
  if (!data || !Array.isArray(data.downloads)) fail('releases.js 格式不正确');
  return data;
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function humanSize(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function today() {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

const PLATFORMS = [
  {
    id: 'mac-arm64',
    platform: 'macOS',
    name: 'Apple Silicon',
    arch: 'arm64',
    min: 'macOS 14 Sonoma 或更高',
    recommended: true,
    sourceStem: (version) => `TokenPeek-${version}-AppleSilicon`,
    releaseStem: (version) => `TokenPeek-${version}-AppleSilicon`,
    sourceDir: MAC_DIST,
    types: ['dmg', 'zip'],
  },
  {
    id: 'mac-intel',
    platform: 'macOS',
    name: 'Intel',
    arch: 'x86_64',
    min: 'macOS 13 Ventura 或更高',
    recommended: false,
    sourceStem: (version) => `TokenPeek-${version}-Intel`,
    releaseStem: (version) => `TokenPeek-${version}-Intel`,
    sourceDir: MAC_DIST,
    types: ['dmg', 'zip'],
  },
];

function findExisting(data, id) {
  return (data.downloads || []).find((item) => item.id === id) || null;
}

function collectPlatforms(data, versions, { copy, allowMissing }) {
  const result = [];
  fs.mkdirSync(DOWNLOAD_DIR, { recursive: true });

  for (const spec of PLATFORMS) {
    const existing = findExisting(data, spec.id);
    const version = versions.mac;
    const files = [];

    for (const type of spec.types) {
      const sourceFile = `${spec.sourceStem(version)}.${type}`;
      const file = `${spec.releaseStem(version)}.${type}`;
      const dest = path.join(DOWNLOAD_DIR, file);
      const source = path.join(spec.sourceDir, sourceFile);

      let target = null;
      if (fs.existsSync(source)) {
        if (copy) fs.copyFileSync(source, dest);
        target = dest;
      } else if (fs.existsSync(dest)) {
        target = dest;
      }

      if (!target) {
        const previous = existing && existing.files
          ? existing.files.find((item) => item.file === file || item.type === type)
          : null;
        if (previous) {
          files.push(previous);
          continue;
        }
        if (allowMissing) {
          console.warn(`  跳过缺失文件：${file}`);
          continue;
        }
        fail(`找不到 ${file}\n  构建对应版本后重试，或加 --allow-missing 保留旧条目。`);
      }

      const bytes = fs.statSync(target).size;
      files.push({
        type,
        label: `下载 .${type}`,
        file,
        size: humanSize(bytes),
        sha256: sha256(target),
      });
    }

    if (files.length === 0) continue;
    result.push({
      id: spec.id,
      platform: spec.platform,
      name: spec.name,
      arch: spec.arch,
      version,
      min: spec.min,
      recommended: Boolean(existing ? existing.recommended : spec.recommended),
      files,
    });
  }

  return result;
}

function parseNotes(data, version) {
  const file = option('--notes-file');
  let notes = [];

  if (file) {
    notes = fs.readFileSync(path.resolve(process.cwd(), file), 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim().replace(/^[-*]\s*/, ''))
      .filter(Boolean);
  } else {
    const raw = option('--notes');
    if (raw) notes = raw.split('|').map((item) => item.trim()).filter(Boolean);
  }

  if (notes.length === 0) {
    const previous = (data.history || []).find((item) => item.version === version);
    if (previous) notes = previous.notes;
  }
  return notes;
}

function writeRelease(data) {
  const output = `window.DEEPSEEK_RELEASE = ${JSON.stringify(data, null, 2)};\n`;
  fs.writeFileSync(RELEASES_FILE, output, 'utf8');
}

function check(data) {
  let failed = 0;
  console.log(`校验 v${data.version} 的下载文件：`);
  for (const item of data.downloads) {
    for (const file of item.files) {
      const local = path.join(DOWNLOAD_DIR, file.file);
      if (!fs.existsSync(local)) {
        console.log(`  缺失  ${file.file}`);
        failed += 1;
        continue;
      }
      const actual = sha256(local);
      if (actual !== file.sha256) {
        console.log(`  不一致 ${file.file}`);
        console.log(`    记录 ${file.sha256}`);
        console.log(`    实际 ${actual}`);
        failed += 1;
      } else {
        console.log(`  通过  ${file.file}`);
      }
    }
  }
  if (failed > 0) fail(`${failed} 个文件校验失败`);
  console.log('全部通过。');
}

const data = loadRelease();

if (hasFlag('--check')) {
  check(data);
  process.exit(0);
}

const version = option('--version');
if (!version) {
  fail('请用 --version 指定版本号，例如 --version 1.2');
}

const date = option('--date', today());
const copy = !hasFlag('--no-copy');
const allowMissing = hasFlag('--allow-missing');
const base = option('--base', data.base || 'downloads/');
const macVersion = option('--mac-version', version);
const versions = { mac: macVersion };

console.log(`准备发布 v${version}（${date}）...`);
if (macVersion !== version) {
  console.log(`平台版本：macOS v${macVersion}`);
}
if (copy) console.log('从构建目录复制安装包到 site/downloads/ ...');

const downloads = collectPlatforms(data, versions, { copy, allowMissing });
const notes = parseNotes(data, version);

data.version = version;
data.date = date;
data.versions = versions;
data.base = base;
data.downloads = downloads;

const history = Array.isArray(data.history) ? data.history : [];
const existingIndex = history.findIndex((item) => item.version === version);
const entry = { version, date, notes };
if (existingIndex >= 0) history[existingIndex] = entry;
else history.unshift(entry);
data.history = history;

writeRelease(data);

console.log('');
console.log(`已更新 ${path.relative(process.cwd(), RELEASES_FILE)}`);
console.log(`版本：v${version}  ${date}`);
if (versions.mac !== version) {
  console.log(`平台版本：macOS v${versions.mac}`);
}
for (const item of downloads) {
  const files = item.files.map((file) => `${file.type.toUpperCase()} ${file.size}`).join(' · ');
  console.log(`  ${item.platform} ${item.name}（v${item.version}）：${files}`);
}
if (notes.length) {
  console.log('更新说明：');
  for (const note of notes) console.log(`  - ${note}`);
}
console.log('');
console.log('下一步：');
console.log('  1. 本地预览：cd site && python3 -m http.server 8080');
console.log('  2. 上传 site/ 到静态托管（GitHub Pages / Cloudflare Pages / 任意服务器）');
if (base.startsWith('downloads/')) {
  console.log('  3. 单文件超过 100 MB 时，GitHub Pages 无法直接放；');
  console.log('     建议把安装包放到 GitHub Releases，再用 --base 指向该版本目录。');
}
