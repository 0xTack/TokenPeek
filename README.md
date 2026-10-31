# DeepSeek 仪表盘 · 发布页

静态下载页，无后端、无外部依赖。页面数据来自 `assets/releases.js`，安装包放在
`downloads/`，也可以用 `--base` 指向 GitHub Releases 或对象存储。

```
site/
  index.html              页面内容（功能、FAQ）
  assets/
    style.css             样式
    app.js                渲染下载卡片、校验值复制、更新日志、二维码弹层
    releases.js           版本、下载文件、SHA-256、更新日志（发布脚本生成）
    icon.png
    screenshot-mac.png
  downloads/              当前版本的安装包
  tools/publish.mjs       发布脚本
  publish.sh              发布脚本入口
```

## 本地预览

```bash
cd site
python3 -m http.server 8080
```

打开 <http://localhost:8080>。也可以直接双击 `index.html`（数据是脚本文件，不受
`file://` 的 fetch 限制），但复制校验值在 `file://` 下会走兼容方案。

## 发布新版本

1. 在项目根目录构建三个版本：

```bash
./package.sh              # Apple Silicon
./package-intel13.sh      # Intel
cd windows && ./build-windows.sh
```

2. 回到 `site/`，更新页面数据：

```bash
cd site

# 直接写在参数里，用 | 分隔多条
./publish.sh --version 1.2 --notes "修复 xxx|新增 yyy"

# 平台版本不同时（例如 macOS 1.1 / Windows 1.3）
./publish.sh --version 1.3 --mac-version 1.1 --windows-version 1.3 \
  --notes "Windows 新增 xxx"

# 或者从文件读取（一行一条，支持 - 开头）
./publish.sh --version 1.2 --notes-file notes.txt
```

脚本会自动：

- 从 `../dist` 和 `../windows/dist` 复制对应版本的安装包到 `downloads/`
- 计算文件大小和 SHA-256
- 更新 `assets/releases.js` 的版本号、日期、下载列表和更新日志
- 保留历史版本记录

常用参数：

| 参数 | 说明 |
|---|---|
| `--version 1.2` | 必填，页面主版本号 |
| `--mac-version 1.1` | 可选，macOS 安装包版本（默认同 `--version`） |
| `--windows-version 1.3` | 可选，Windows 安装包版本（默认同 `--version`） |
| `--date 2026-11-15` | 可选，默认今天 |
| `--notes "a\|b"` | 更新说明，`\|` 分隔 |
| `--notes-file notes.txt` | 从文件读取更新说明 |
| `--base URL` | 安装包地址前缀，默认 `downloads/` |
| `--no-copy` | 不复制文件，只重新计算校验值 |
| `--allow-missing` | 某个平台暂时没构建时，保留旧条目 |
| `--check` | 只校验 `downloads/` 里的文件与记录的 SHA-256 是否一致 |

3. 校验：

```bash
./publish.sh --check
```

## 部署

### 方案 A：GitHub Pages + GitHub Releases（推荐）

GitHub Pages 单个文件上限 100 MB，而 Windows 包约 153 MB，所以把安装包放到
Releases，页面放 Pages。

1. 新建仓库，把 `site/` 里的 `index.html`、`assets/`、`.nojekyll` 推上去。
   `downloads/` 可以不上传。
2. 新建 Release，tag 用 `v1.1`，把三个版本的 5 个安装包作为附件上传。
3. 用 Releases 地址作为下载前缀，重新生成数据：

```bash
cd site
./publish.sh --version 1.1 --no-copy \
  --base "https://github.com/<用户名>/<仓库>/releases/download/v1.1/" \
  --notes-file notes.txt
```

4. 仓库 Settings → Pages → 选择分支根目录，保存。
5. 打开 `https://<用户名>.github.io/<仓库>/`。

> 文件名必须与 Releases 附件名完全一致。脚本会用 `encodeURIComponent` 处理中文，
> 浏览器和 GitHub 都能正确解析。

### 方案 B：Cloudflare Pages + R2

Cloudflare Pages 单文件上限 25 MB，Windows 包同样需要放 R2：

1. Pages 直接拖拽 `site/` 目录（不含 `downloads/`）。
2. 把安装包上传到 R2，开启公开访问。
3. 用 R2 公共域名作为 `--base` 重新生成数据。

### 方案 C：自己的服务器 / 对象存储

把整个 `site/`（含 `downloads/`）上传到任何静态服务器即可，默认的
`base: "downloads/"` 会直接生效。Nginx / Caddy / OSS / COS 都可以。

## 修改页面内容

- 文案、功能卡片、FAQ：编辑 `index.html`
- 配色、排版、响应式：编辑 `assets/style.css`
- 下载卡片、校验值复制、更新日志逻辑：编辑 `assets/app.js`
- 版本与下载数据：只改 `assets/releases.js`（建议用 `publish.sh`）

## 自定义

- **图标**：替换 `assets/icon.png`（建议 256×256）
- **截图**：替换 `assets/screenshot-mac.png`
- **社交分享图**：`index.html` 里的 `og:image` 目前是相对路径。部署后建议改成
  完整 URL，例如 `https://your.domain/assets/screenshot-mac.png`
- **自定义域名**：加 `CNAME` 文件（GitHub Pages）或在托管平台绑定域名

## 其它

- 页面没有任何统计脚本、Cookie 或外部字体，完全静态
- 下载文件名含中文时，浏览器会显示编码后的地址，但下载后的文件名正常
- 发布新版本后，旧的安装包仍留在 `downloads/`，可手动删除旧版本文件
