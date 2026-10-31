# DeepSeek 仪表盘（菜单栏）

一个小巧的 macOS 菜单栏工具：显示 DeepSeek 当前是**高峰**还是**空闲**时段，并按官方人民币价格计算 token 费用。

价格来源：<https://api-docs.deepseek.com/zh-cn/quick_start/pricing/>

## 功能

- 菜单栏常驻：`☾ 空闲`（绿色）/ `⚡ 高峰`（橙色）
- 点击查看距离下次切换还有多久
- Flash / Pro 两档价格，空闲价与高峰价并排显示
- 自动读取**本机 OpenCode** 的用量：今日 / 近 7 天 / 本月
- 数据源可切换：官方 · 按 Key / 自定义 App（有数据时显示）/ OpenCode · 全部 / DeepSeek / Ollama
- 按 API 名称、API Key 或自定义 App 列出用量 **Top 3**（token 数排名）
- 本地模型（Ollama）按 DeepSeek 同档价格显示「已省」
- 显示缓存命中率、近 7 天每日命中率趋势，并给出对应的优化建议
- 右键菜单：开机自动启动、价格来源、退出

## 计费规则

| 模型 | 缓存命中（空闲/高峰） | 缓存未命中（空闲/高峰） | 输出（空闲/高峰） |
|---|---|---|---|
| deepseek-flash | ¥0.02 / ¥0.04 | ¥1 / ¥2 | ¥4 / ¥8 |
| deepseek-v4-pro | ¥0.15 / ¥0.30 | ¥4.5 / ¥9 | ¥13.5 / ¥27 |

单位：元 / 百万 tokens。

高峰时段：北京时间周一至周五 9:00–12:00、14:00–18:00，中国法定节假日除外。其余时间（含周末和节假日全天）为空闲时段，价格为高峰的 5 折。

内置 2025–2026 年法定节假日。2027 年放假安排公布后可再补充。

## 我的用量从哪里来

### 本机 OpenCode 模式

菜单栏里的「我的用量」读取本机 OpenCode 的数据库：

```
~/.local/share/opencode/opencode.db
```

只统计本机 OpenCode 的 assistant 消息，按每条消息的时间判断当时是高峰还是空闲。

- 数据源菜单可以切换：OpenCode · 全部、DeepSeek、Ollama
- API 用量 Top 3 按 token 数排序
- **费用只统计 DeepSeek**；其他 API 只有 token 数，因为本地没有统一的人民币价格
- OpenCode 的免费模型（provider `opencode` 或名字带 `-free`）已过滤，不计入统计
- Ollama 本地模型不产生 DeepSeek 费用，但会按当前选择的 Flash/Pro 价格折算为**「已省」**，显示在总计和排名里，仅供参考
- 默认的 DeepSeek 视图也会在总计下面显示「本地模型已省」；如果当天没有本地用量会显示 ¥0.00，切到「近 7 天 / 本月」或 Ollama 数据源即可看到实际金额

用量按模型 ID 分组，模型名直接来自 OpenCode 的记录。

缓存命中率 = 缓存命中 tokens ÷（缓存命中 + 缓存未命中）。下方会显示近 7 天每日命中率小柱状图，并按命中率高低给出建议。

- **不需要登录 DeepSeek 账号**
- 不上传任何数据
- 只覆盖这台 Mac 上的 OpenCode，不包含网页端、手机端或其他客户端

### 官方 · 按 API Key 模式

切到「官方 · 按 Key」后，读取的是 **DeepSeek 官方网页同款数据**，包含所有客户端、所有 API Key：

- 总计 + API Key 用量 Top 3（按 token）
- 官方人民币费用
- 缓存命中率 + 近 7 天趋势

鉴权需要**网页登录 Token**，不是 `sk-` API Key。推荐直接点菜单栏里的「登录官方账户（自动获取 Token）」；也可以手动获取：

1. 登录 <https://platform.deepseek.com/usage>
2. 按 `⌥⌘I` 打开开发者工具，切到 Console
3. 点菜单栏里的「复制命令」，粘贴到 Console 回车：

```js
JSON.parse(localStorage.getItem('userToken')).value
```

4. 把输出的那串 Token 粘贴到菜单栏输入框，保存

`sk-` API Key 只能调用模型和查余额，读不了用量；官方网页用的是登录 Token。

Token 只保存在本机文件（`~/Library/Application Support/DeepSeekCost/platform-token`，权限 600），不上传、不写日志。官方接口是网页内部接口（`/api/v0/usage/by_api_key/*`），不是公开 API，平台改版时可能失效；失效后重新登录或等待适配。

如果要看官方网页账单，也可以直接打开：

<https://platform.deepseek.com/usage>

API Key 本身只能查询余额（不是用量）：

```bash
curl https://api.deepseek.com/user/balance \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY"
```

### 自定义 App 模式

任何脚本或插件都可以上报一条用量，菜单栏会按 App 排名：

```bash
~/Applications/DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost \
  --report --app Obsidian --model deepseek-flash \
  --hit 0 --miss 1000 --output 200
```

参数：

- `--hit`：缓存命中输入 tokens
- `--miss`：缓存未命中输入 tokens（缓存写入也算这里）
- `--output`：输出 tokens（含推理）
- `--cost`：可选，人民币费用；不填则按 DeepSeek 同档价格和记录时间自动计算
- `--time`：可选，ISO 8601；不填用当前时间

记录写入：

```
~/Library/Application Support/DeepSeekCost/custom-usage.jsonl
```

一行一条：

```json
{"time":"2026-10-31T09:00:00+08:00","app":"Obsidian","model":"deepseek-flash","hit":0,"miss":1000,"output":200}
```

然后在「我的用量」里选「自定义 App」，就能看到总计、App 用量 Top 3、缓存命中率和每日趋势。

## macOS 打不开？

如果提示「无法验证开发者」或「已损坏，应移到废纸篓」，**先不要删除 App**。

详细步骤见 [macOS 打开说明](docs/macOS-打开说明.md)，在线版：

<https://xiaoan223.github.io/deepseek-dashboard/macos-open.html>

## 编译安装

```bash
./build.sh
```

脚本会编译、签名，安装到 `~/Applications/DeepSeek仪表盘.app` 并启动。

## 打包发布版

```bash
./package.sh              # Apple Silicon（arm64，macOS 14+）
./package-intel13.sh      # Intel（x86_64，macOS 13+）
cd windows && ./build-windows.sh   # Windows 11 x64
```

产物：

- `dist/DeepSeek仪表盘-1.1-AppleSilicon.dmg` / `.zip`
- `dist/DeepSeek仪表盘-1.1-Intel.dmg` / `.zip`
- `windows/dist/DeepSeekDashboard-1.3-Windows-x64.zip`

macOS 两个版本也会自动复制到桌面。

## 卸载

```bash
pkill -f "DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost"
rm -rf ~/Applications/DeepSeek仪表盘.app
rm -f ~/Library/LaunchAgents/local.deepseekcost.plist
```

## Windows 版

`windows/` 目录是 Windows 11 移植版（Electron，绿色版 zip）：

```bash
cd windows
npm install
./build-windows.sh
```

产物：`windows/dist/DeepSeekDashboard-1.3-Windows-x64.zip`。功能、数据来源和命令行参数见 [windows/README-Windows.md](windows/README-Windows.md)。

## 发布页（下载站）

`site/` 是静态发布页，包含功能介绍、价格表、三端下载、校验值和更新日志，可直接部署到
GitHub Pages / Cloudflare Pages / 任意静态服务器：

```bash
cd site
./publish.sh --version 1.3 --mac-version 1.1 --windows-version 1.3
python3 -m http.server 8080
```

发布流程、部署方式和参数说明见 [site/README.md](site/README.md)。

## 支持作者

如果这个工具帮到了你，可以在面板最下方点「请我喝杯咖啡」，微信扫码即可。

## 菜单栏里找不到图标？

如果用了 Hidden Bar 之类的收纳工具，新图标可能被自动收进折叠区：

1. 点菜单栏的折叠箭头展开，找到 `空闲` / `高峰`
2. 按住 `⌘` 把它拖到折叠箭头右侧，之后就会固定显示

## 自检

```bash
"$HOME/Applications/DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost" --self-test
"$HOME/Applications/DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost" --check
"$HOME/Applications/DeepSeek仪表盘.app/Contents/MacOS/DeepSeekCost" --usage
```

## 开源协议

本项目使用 [MIT License](LICENSE)。

## 赞赏码不进入仓库

`donation-qr.png` 是作者本人的微信赞赏码，默认不提交到仓库，只在本机打包时注入：

- macOS：放在项目根目录，`build.sh` / `package.sh` / `package-intel13.sh` 会自动复制到 App 的 Resources
- Windows：`windows/build-windows.sh` 会把根目录的 `donation-qr.png` 复制到 `windows/assets/` 再打包
- 没有这个文件时，两个平台都会自动隐藏「请我喝杯咖啡」入口，源码构建不受影响

官方发布的安装包包含赞赏码；你也可以换成自己的，或者直接不放。
