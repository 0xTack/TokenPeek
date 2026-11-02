# TokenPeek（Windows 版）

macOS 版的 Windows 移植。常驻托盘，显示 DeepSeek 当前是**高峰**还是**空闲**时段，并按官方人民币价格统计本机用量。

## 系统要求

- Windows 11（64 位）；Windows 10 21H2 及以上也可运行
- 无需安装 Node.js、.NET 或额外运行环境

## 运行

解压 `DeepSeekDashboard-1.3-Windows-x64.zip`，双击 `DeepSeekDashboard.exe`。

- 托盘图标：绿色月牙 = 空闲；橙色闪电 = 高峰
- 左键点图标打开面板；右键打开菜单（刷新、开机自启、价格来源、退出）
- 关闭面板不会退出，程序继续在托盘运行
- 资源管理器里的 `resources/sqlite3.exe` 是读取 OpenCode 数据库用的，请勿删除

## 功能

- 高峰 / 空闲状态，以及距离下次切换的倒计时
- Flash / Pro 两档价格，空闲价与高峰价并排显示，每月自动检查官方定价
- 读取本机 OpenCode 用量：今日 / 近 7 天 / 本月 / 全部（本月为自然月，每月 1 日重置）
- 数据源：OpenCode · 全部 / DeepSeek / Ollama / 自定义 App
- 按模型或 App 列出用量 Top 3，可展开全部
- 缓存命中率 + 近 7 天趋势 + 优化建议
- 本地模型按 DeepSeek 同档价格折算「已省」
- 官方 API Key 余额：绑定后在面板显示 DeepSeek 官方账户余额（充值 / 赠送），Key 只存本机
- 本地 App 用量：自动发现 Wetokens 数据库、Claude Code、Codex、Gemini CLI 的本地记录，数据源里可直接切换
- 通用本地接口：在「本地接口」里指定本地 JSON/JSONL 文件或目录，或内网 HTTP 地址
- 本地收集接口：监听 `127.0.0.1:47123`，其他脚本可 `POST /usage` 上报用量
- 开机自动启动

暂未包含：官方账户 Token 登录、官方按 Key 用量。这些依赖网页内部接口，后续版本再加。

## 数据位置

```
%APPDATA%\DeepSeekCost\
  settings.json         面板设置
  api-key               DeepSeek API Key（仅本机）
  local-source.json     本地文件 / 本地 HTTP 接口配置
  local-usage.jsonl     收集接口收到的用量
  pricing.json          官方价格缓存
  custom-usage.jsonl    自定义 App 上报记录
  last-usage.txt        --usage 的最近输出
```

OpenCode 数据库会自动在这些位置查找：

```
%USERPROFILE%\.local\share\opencode\opencode.db
%LOCALAPPDATA%\opencode\opencode.db
%APPDATA%\opencode\opencode.db
```

## 自定义 App 上报

```bat
DeepSeekDashboard.exe --report --app Obsidian --model deepseek-flash --hit 0 --miss 1000 --output 200
```

参数：

- `--hit`：缓存命中输入 tokens
- `--miss`：缓存未命中输入 tokens（缓存写入也算这里）
- `--output`：输出 tokens（含推理）
- `--cost`：可选，人民币费用；不填按记录时间自动计算
- `--time`：可选，ISO 8601；不填用当前时间

写入 `%APPDATA%\DeepSeekCost\custom-usage.jsonl`，一行一条：

```json
{"time":"2026-10-31T09:00:00+08:00","app":"Obsidian","model":"deepseek-flash","hit":0,"miss":1000,"output":200}
```

## 本地 App 用量

自动查找并接入：

- Wetokens / cc-switch 本地数据库：`%LOCALAPPDATA%\Wetokens\switch\cc-switch.db`
- Claude Code：`~/.claude/projects/**/*.jsonl`
- Codex：`~/.codex/sessions/**/*.jsonl`
- Gemini CLI：`~/.gemini` 下的会话 JSON

第三方 App 只统计 token，不折算费用；在面板「数据源」里切换。

## 通用本地接口

点面板底部「本地接口」，可填：

- 文件或目录：JSON / JSONL
- 本地 HTTP：仅 localhost / 127.0.0.1 / 内网地址

支持数组、`{"records":[...]}` 或 JSONL。每条记录支持：

```json
{"time":"2026-10-31T09:00:00+08:00","app":"Obsidian","model":"deepseek-flash","hit":0,"miss":1000,"output":200}
```

也可用 `input_tokens` / `output_tokens` / `cache_read_tokens` 等字段，会自动换算。

## 收集接口

本机监听 `http://127.0.0.1:47123/usage`（端口占用时自动顺延）：

```bat
curl -X POST http://127.0.0.1:47123/usage -H "Content-Type: application/json" -d "{\"app\":\"Obsidian\",\"model\":\"deepseek-flash\",\"miss\":1000,\"output\":200}"
```

## 命令行

```bat
DeepSeekDashboard.exe --usage       :: 打印今日 / 近 7 天 / 本月 / 全部
DeepSeekDashboard.exe --self-test   :: 时段判断自检
DeepSeekDashboard.exe --check       :: 当前时段与价格
```

Windows 的 GUI 程序没有控制台，输出同时写入 `%APPDATA%\DeepSeekCost\last-usage.txt` 等文件。

如果在批处理或脚本里上报，建议用 `start /wait` 等待写入完成：

```bat
start /wait "" DeepSeekDashboard.exe --report --app Obsidian --miss 1000 --output 200
```


## 从源码构建

在 macOS 或 Windows 上：

```bash
cd windows
npm install
./build-windows.sh
```

产物：`windows/dist/DeepSeekDashboard-1.1-Windows-x64.zip`（x64 绿色版）。
构建脚本会自动下载 Windows 版 `sqlite3.exe` 并一起打包。

## 说明

- 只统计本机 OpenCode 的 assistant 消息，不含网页端、手机端
- 费用只统计 DeepSeek；Ollama 等本地模型显示「已省」，仅供参考
- 官方余额通过 `https://api.deepseek.com/user/balance` 查询，只读、不产生费用；API Key 明文保存在本机 `api-key` 文件，请勿把该文件发给他人
- 不上传任何用量或文件
- 面板最下方点「请我喝杯咖啡」可打开微信赞赏码
- 未做代码签名，Windows SmartScreen 可能提示；点「更多信息 → 仍要运行」
