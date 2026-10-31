(() => {
  'use strict';

  const release = window.DEEPSEEK_RELEASE;
  if (!release) return;

  const ICONS = {
    macOS:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.4 12.7c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.2-2.8.9-3.5.9-.7 0-1.8-.9-3-.9-1.5 0-3 .9-3.8 2.3-1.6 2.8-.4 7 1.2 9.3.8 1.1 1.7 2.3 2.9 2.3 1.2 0 1.6-.7 3-.7s1.8.7 3 .7c1.3 0 2.1-1.1 2.9-2.2.9-1.2 1.3-2.4 1.3-2.5-.1 0-2.6-1-2.6-3.9ZM14.1 5.6c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.8 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.8-1.3Z"/></svg>',
    Windows:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 5.5 10.4 4.4v7.1H3V5.5Zm8.6-1.3L21 2.5v9H11.6V4.2ZM3 12.6h7.4v7.1L3 18.6v-6Zm8.6 0H21v9l-9.4-1.3v-7.7Z"/></svg>',
  };

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function fileUrl(file) {
    if (/^https?:\/\//i.test(file)) return file;
    const base = release.base || '';
    return `${base}${encodeURIComponent(file)}`;
  }

  function applyMeta() {
    $$('[data-version]').forEach((node) => {
      node.textContent = `v${release.version}`;
    });
    if (release.versions) {
      $$('[data-mac-version]').forEach((node) => {
        node.textContent = `v${release.versions.mac}`;
      });
      $$('[data-win-version]').forEach((node) => {
        node.textContent = `v${release.versions.windows}`;
      });
    }
    $$('[data-date]').forEach((node) => {
      node.textContent = release.date;
    });
    const year = release.date ? release.date.slice(0, 4) : String(new Date().getFullYear());
    $$('[data-year]').forEach((node) => {
      node.textContent = year;
    });
  }

  function copyText(text, button) {
    const done = () => {
      const original = button.textContent;
      button.textContent = '已复制';
      window.setTimeout(() => {
        button.textContent = original;
      }, 1400);
    };

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
      return;
    }
    fallbackCopy(text, done);
  }

  function fallbackCopy(text, done) {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand('copy');
      done();
    } catch {
      // 浏览器不允许复制时，至少让用户可以手动选中
      window.prompt('复制下面的校验值：', text);
    } finally {
      document.body.removeChild(area);
    }
  }

  function buildCard(item) {
    const card = el('article', `dl-card${item.recommended ? ' recommended' : ''}`);
    if (item.recommended) card.appendChild(el('span', 'dl-badge', '推荐'));

    const head = el('div', 'dl-head');
    const icon = el('div', 'os-icon');
    icon.innerHTML = ICONS[item.platform] || '';
    const headText = el('div');
    headText.appendChild(el('h3', null, item.platform));
    headText.appendChild(el('p', null, item.name));
    head.appendChild(icon);
    head.appendChild(headText);
    card.appendChild(head);

    const meta = el('dl', 'dl-meta');
    const addMeta = (term, desc) => {
      const wrap = el('div');
      wrap.appendChild(el('dt', null, term));
      wrap.appendChild(el('dd', null, desc));
      meta.appendChild(wrap);
    };
    addMeta('系统要求', item.min);
    addMeta('架构', item.arch);
    addMeta('版本', `v${item.version || release.version}`);
    addMeta('文件', item.files.map((file) => file.type).join(' / '));
    card.appendChild(meta);

    if (item.extra) {
      card.appendChild(el('p', 'dl-extra', item.extra));
    }

    const actions = el('div', 'dl-actions');
    item.files.forEach((file, index) => {
      const link = el('a', `btn${index === 0 ? ' btn-primary' : ''}`);
      link.href = fileUrl(file.file);
      link.setAttribute('download', file.file);
      link.rel = 'noopener';
      link.appendChild(document.createTextNode(file.label));
      link.appendChild(el('span', null, file.size));
      actions.appendChild(link);
    });
    card.appendChild(actions);

    item.files.forEach((file) => {
      const row = el('div', 'dl-hash');
      const code = el('code', null, file.sha256);
      code.title = file.sha256;
      const button = el('button', null, '复制');
      button.type = 'button';
      button.setAttribute('aria-label', `复制 ${file.file} 的 SHA-256`);
      button.addEventListener('click', () => copyText(file.sha256, button));
      row.appendChild(code);
      row.appendChild(button);
      card.appendChild(row);
    });

    return card;
  }

  function renderDownloads() {
    const grid = $('#download-grid');
    if (!grid) return;
    grid.textContent = '';
    release.downloads.forEach((item) => grid.appendChild(buildCard(item)));
  }

  function renderChangelog() {
    const list = $('#changelog-list');
    if (!list || !Array.isArray(release.history)) return;
    list.textContent = '';
    release.history.forEach((entry) => {
      const item = el('div', 'tl-item');
      const head = el('div', 'tl-head');
      head.appendChild(el('strong', null, `v${entry.version}`));
      head.appendChild(el('time', null, entry.date));
      item.appendChild(head);
      const notes = el('ul');
      entry.notes.forEach((note) => notes.appendChild(el('li', null, note)));
      item.appendChild(notes);
      list.appendChild(item);
    });
  }

  applyMeta();
  renderDownloads();
  renderChangelog();
})();
