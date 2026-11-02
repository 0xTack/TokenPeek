'use strict';

const http = require('http');
const fs = require('fs');
const paths = require('./paths');
const localusage = require('./localusage');

const DEFAULT_PORT = 47123;
const MAX_BODY = 1024 * 1024;

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function startCollector({ onRecord, preferredPort = DEFAULT_PORT } = {}) {
  return new Promise((resolve) => {
    let port = preferredPort;
    let attempts = 0;
    let settled = false;

    const server = http.createServer(async (req, res) => {
      const url = new URL(req.url || '/', `http://127.0.0.1:${port}`);
      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        });
        res.end();
        return;
      }
      if (req.method === 'GET' && url.pathname === '/health') {
        send(res, 200, { ok: true, service: 'tokenpeek', port });
        return;
      }
      if (req.method === 'POST' && url.pathname === '/usage') {
        try {
          const text = await readBody(req);
          const data = JSON.parse(text || '{}');
          const records = localusage.standardizePayload(data, 'local', Date.now());
          if (records.length === 0) {
            send(res, 400, { ok: false, error: '没有可识别的 token 字段' });
            return;
          }
          paths.ensureDir(paths.dataDir());
          const lines = records.map((record) => JSON.stringify(record)).join('\n');
          fs.appendFileSync(paths.localUsageFile(), `${lines}\n`, 'utf8');
          if (typeof onRecord === 'function') onRecord();
          send(res, 200, { ok: true, count: records.length });
        } catch (error) {
          send(res, 400, { ok: false, error: error.message || '解析失败' });
        }
        return;
      }
      send(res, 404, { ok: false, error: 'not found' });
    });

    server.on('error', (error) => {
      if (error.code === 'EADDRINUSE' && attempts < 12) {
        attempts += 1;
        port += 1;
        server.listen(port, '127.0.0.1');
        return;
      }
      if (!settled) {
        settled = true;
        resolve({ port: null, error: error.message || '启动失败', close: () => {} });
      }
    });

    server.on('listening', () => {
      if (settled) return;
      settled = true;
      resolve({
        port,
        close: () => {
          try {
            server.close();
          } catch {
            // 忽略
          }
        },
      });
    });

    server.listen(port, '127.0.0.1');
  });
}

module.exports = { startCollector, DEFAULT_PORT };
