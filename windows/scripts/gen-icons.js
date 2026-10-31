'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const ASSETS = path.join(ROOT, 'assets');

// ---------- 最小 PNG 编码器 ----------
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (let i = 0; i < buffer.length; i += 1) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuffer = Buffer.from(type, 'ascii');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0);
  return Buffer.concat([length, typeBuffer, data, crc]);
}

function encodePNG(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- 抗锯齿绘制 ----------
const SCALE = 4;

function canvas(size) {
  return {
    size,
    data: new Uint8ClampedArray(size * size * 4),
  };
}

function paint(cv, x, y, color) {
  if (x < 0 || y < 0 || x >= cv.size || y >= cv.size) return;
  const i = (y * cv.size + x) * 4;
  cv.data[i] = color[0];
  cv.data[i + 1] = color[1];
  cv.data[i + 2] = color[2];
  cv.data[i + 3] = 255;
}

function fillShape(cv, test, color) {
  const n = cv.size;
  for (let y = 0; y < n; y += 1) {
    for (let x = 0; x < n; x += 1) {
      const px = (x + 0.5) / SCALE;
      const py = (y + 0.5) / SCALE;
      if (test(px, py)) paint(cv, x, y, color);
    }
  }
}

function resolve(cv) {
  const n = cv.size;
  const outSize = n / SCALE;
  const out = Buffer.alloc(outSize * outSize * 4);
  for (let y = 0; y < outSize; y += 1) {
    for (let x = 0; x < outSize; x += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      for (let sy = 0; sy < SCALE; sy += 1) {
        for (let sx = 0; sx < SCALE; sx += 1) {
          const i = ((y * SCALE + sy) * n + (x * SCALE + sx)) * 4;
          const alpha = cv.data[i + 3];
          r += cv.data[i] * alpha;
          g += cv.data[i + 1] * alpha;
          b += cv.data[i + 2] * alpha;
          a += alpha;
        }
      }
      const o = (y * outSize + x) * 4;
      if (a > 0) {
        out[o] = Math.round(r / a);
        out[o + 1] = Math.round(g / a);
        out[o + 2] = Math.round(b / a);
      }
      out[o + 3] = Math.round(a / (SCALE * SCALE));
    }
  }
  return { width: outSize, height: outSize, pixels: out };
}

function drawCircle(cx, cy, radius, color) {
  const cv = canvas(32 * SCALE);
  fillShape(cv, (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2, color);
  return resolve(cv);
}

function drawCrescent(cx, cy, radius, cutX, cutY, cutRadius, color) {
  const cv = canvas(32 * SCALE);
  fillShape(
    cv,
    (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2
      && (x - cutX) ** 2 + (y - cutY) ** 2 > cutRadius ** 2,
    color,
  );
  return resolve(cv);
}

function drawPolygon(points, color) {
  const cv = canvas(32 * SCALE);
  fillShape(cv, (x, y) => {
    let inside = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i, i += 1) {
      const [xi, yi] = points[i];
      const [xj, yj] = points[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  }, color);
  return resolve(cv);
}

function writePng(name, image) {
  const file = path.join(ASSETS, name);
  fs.writeFileSync(file, encodePNG(image.width, image.height, image.pixels));
  console.log(`写入 ${file}`);
}

// ---------- ICO ----------
function buildIco(pngFiles) {
  const images = pngFiles.map(({ size, file }) => ({ size, data: fs.readFileSync(file) }));
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  const entries = Buffer.alloc(16 * images.length);
  let offset = 6 + entries.length;
  images.forEach(({ size, data }, index) => {
    const base = index * 16;
    entries[base] = size >= 256 ? 0 : size;
    entries[base + 1] = size >= 256 ? 0 : size;
    entries[base + 2] = 0;
    entries[base + 3] = 0;
    entries.writeUInt16LE(1, base + 4);
    entries.writeUInt16LE(32, base + 6);
    entries.writeUInt32LE(data.length, base + 8);
    entries.writeUInt32LE(offset, base + 12);
    offset += data.length;
  });
  return Buffer.concat([header, entries, ...images.map((item) => item.data)]);
}

function main() {
  fs.mkdirSync(ASSETS, { recursive: true });

  const green = [47, 191, 95];
  const orange = [255, 159, 10];

  // 空闲：月牙
  writePng('tray-idle.png', drawCrescent(16.5, 16, 10.5, 20.5, 13, 8.5, green));
  // 高峰：闪电
  writePng(
    'tray-peak.png',
    drawPolygon(
      [[18.4, 3.5], [8.6, 18.2], [14.6, 18.2], [12.8, 28.5], [23.4, 13.2], [16.9, 13.2]],
      orange,
    ),
  );

  // 应用图标：从 AppIcon-1024.png 生成 ICO
  const source = path.join(ROOT, '..', 'AppIcon-1024.png');
  if (fs.existsSync(source)) {
    const tmp = path.join(ROOT, '.icon-tmp');
    fs.mkdirSync(tmp, { recursive: true });
    const sizes = [16, 24, 32, 48, 64, 128, 256];
    const files = [];
    for (const size of sizes) {
      const file = path.join(tmp, `icon-${size}.png`);
      execFileSync('sips', ['-z', String(size), String(size), source, '--out', file], {
        stdio: 'ignore',
      });
      files.push({ size, file });
    }
    fs.writeFileSync(path.join(ASSETS, 'icon.ico'), buildIco(files));
    console.log(`写入 ${path.join(ASSETS, 'icon.ico')}`);
    fs.rmSync(tmp, { recursive: true, force: true });
  } else {
    console.warn(`未找到 ${source}，跳过 icon.ico`);
  }
}

main();
