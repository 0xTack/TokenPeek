# TokenPeek（原 DeepSeek 仪表盘）— 交接说明

## 一句话状态

macOS 菜单栏 Token 用量 / 花费工具。当前版本 **1.5（Build 6，已发布）**，已安装 `/Applications/TokenPeek.app`。主包 Apple Silicon arm64 / macOS 14+；Intel x86_64 / macOS 13 包已构建并发布，但仍未在真实 macOS 13 机器上验证。

> 2026-11-02 本轮完整总结（发布信息、命令、待办）见 `docs/2026-11-02-交接总结.md`。

## 最近一轮改动（2026-11-01 晚，下一个对话先看这里）

`main.swift` 现约 8430 行。本轮在已安装的 1.5 上继续改，版本号没动：

- **深色模式补全**：新增 `AppAppearance`（跟随系统 / 浅色 / 深色）；`ThemedRoot` 给所有 SwiftUI 窗口显式注入 `colorScheme`；设置窗口、面板、AI 页、日志页都不会再在深色下发白。菜单不再强制跟 App 主题，改为跟随系统。
- **右键菜单重写**：从原生 `NSMenu` 换成 `StatusMenuView` + 自定义 `StatusMenuPanel`（`NSPanel`）。背景用 `NSVisualEffectView .menu`，浅色/深色都是系统半透明材质；**定位和系统菜单一致：左边缘比状态栏图标再向左溢出约 12pt，向右展开，右边放不下时整体左移**（实测对齐了 LuLu 原生菜单）；打开/关闭有淡入淡出。**没有 `--menu` 调试参数了**。
- **设置窗口位置**：先按最终内容尺寸 `setContentSize` 再居中（原来先居中后改尺寸，会右/下偏约 15pt）；在鼠标所在屏幕的 `visibleFrame` 里居中，并限制在可视区域内。
- **总花费口径**：去掉账号上的「计入总花费」勾选；只要账号已登录（有 Token），它的历史累计花费就一律计入总花费。
- **状态圆环配色**：新增 `StatusRingStyle`（经典 / 柔和 / 浅色），默认「柔和」（方案 A）；设置 →「状态圆环」可切换并实时预览空闲 / 高峰 / 低余额三色，写入 `statusRingStyle` 并纳入 iCloud 备份。
- **趋势图（2026-11-01 深夜再简化）**：只保留一条总用量平滑曲线；已删除「用量 / 模型」切换和下方「每日 · 近 7 天」柱状图。折线改为单调三次插值（Fritsch–Carlson），不会过冲；高度 40pt，去掉三横网格，只留一条极淡基线。线色随外观自适应（深色低饱和蓝 / 浅色加深一档）。末端不画圆点，圆头收尾，画布左右留 1.5pt 避免圆头被裁。仍跟随「近 7 天 / 本月 / 全部（近 30 天）」，选「今日」隐藏。
- **用量数字 / 柱状图**：`usageDisplayMode` 存 UserDefaults；设置里可选「用量显示」；面板上原来的切换图标已删除，只保留设置里的入口。OpenCode / 自定义 / 本地来源支持，官方账号区仍显示数字。
- **液态玻璃面板**：`ContentView` 背景从实心 `textBackgroundColor` 换成 `PanelGlassBackground`（`NSVisualEffectView .popover` 模糊 + 深浅色乳白/烟灰渐变）。浅色和深色都是半透明磨砂质感，文字保持可读。
- **数据层**：`DailyRate` 新增 `model` 和 `output`；OpenCode / 官方 / 自定义 / 本地来源的每日聚合从 7 天扩到 `min(本月 1 号, 今天-29 天)`，官方接口仍按 30 天上限收敛。
- **面板叉号移除**：`ContentView.header` 不再画叉号；popover 用 `.transient`，点外面关闭。主窗口仍有关闭按钮。
- **上一轮遗留并已落地**：账号重命名（名字旁铅笔）、新账号 `nonPersistent` 登录会话、重复 Token 拦截、价格手动编辑、价格页网址识别（`pricing-overrides.json`）、AI 接入步骤页、更新日志 / 反馈、iCloud 备份包含自定义价格与新增设置键。

本轮验证：`swiftc -sdk …MacOSX26.5.sdk -O …` 通过；`--self-test` 通过；`./build.sh` 已重新安装。趋势图用离屏 `ImageRenderer` 渲染了浅色/深色 × 7 天/30 天四张样图确认曲率、标签和对比度，并在主窗口实机看过深色 7 天效果。价格网址识别只用本地 markdown / HTML 样例测过（当前环境 shell 无外网），没有对真实官网做联网验证。

## 命名 / 路径

- 产品名：**TokenPeek**（不再显示中文名「瞄」）
- Bundle ID：`local.deepseekcost`（保留，兼容旧数据）
- 可执行文件：`DeepSeekCost`（保留）
- 源码：`/Users/xa/Documents/Default Project/DeepSeekCost/`
- 主程序：`main.swift`（单文件）
- 已安装：`/Applications/TokenPeek.app`
- 桌面产物：`~/Desktop/TokenPeek-1.5-AppleSilicon.dmg` / `.zip`、`TokenPeek-1.5-Intel.dmg` / `.zip`
- GitHub Release：<https://github.com/0xTack/TokenPeek/releases/tag/v1.5>
- 旧版 DeepSeek 仪表盘已从 `/Applications` 移除

## 1.5 已实现

### 多账号（DeepSeek）
- 可添加多个 DeepSeek 官方账号，数据源菜单「DeepSeek」为二级菜单，列出所有账号
- 每个账号独立 Token、用量、余额、总花费
- 总花费 = 所有已登录（有 Token）官方账号的历史累计 + OpenCode / 自定义 / 本地来源 + 手动记录；不再有「计入总花费」勾选
- 账号管理：添加 / 编辑 / 删除 / 重命名 / 网页登录获取 Token
- 新增账号时使用全新的无痕会话，不复用已登录的网页账号；同一个 Token 不能重复添加
- 旧 `official-accounts.json` 自动迁移；旧名「官方账号」自动改为 DeepSeek

### 本地来源
- `~/Library/Application Support/DeepSeekCost/sources/*.jsonl` 自动发现
- 可给来源配置命令，刷新时执行（20 秒超时）；支持 `$DS_SOURCE_FILE` / `$DS_SOURCE_NAME`
- 「管理账号与来源」里增删改、运行、打开文件夹
- 「让 AI 帮我接入新来源」打开步骤页：可复制提示词到任意 AI，也可直接打开 ChatGPT / Claude / DeepSeek
- 完整接入说明：`docs/自定义来源接入说明.md`（DeepSeek / OpenAI / JSONL 规范 / AI 提示词）

### 总花费 / 花费构成
- 统计区间下拉最后一行「总花费」
- 点击「总花费」打开环形图，显示各来源历史累计占比
- 官方多账号统计所有已登录（有 Token）账号
- OpenCode 的 DeepSeek 部分在官方账号存在时自动排除，避免重复
- 手动记录按名称分片；同名时优先使用手动记录
- 金额显示支持人民币 / 美元，设置里可调汇率

### 手动记录
- 设置 →「手动花费」：一次性 / 每月订阅
- 订阅从开始月份累计到当前月；一次性只计一次
- 可删除；进入总花费

### 设置
- 窗口不透明度 80%–100%，100% 不透明白底
- 外观模式：跟随系统 / 浅色 / 深色
- 5 个模块开关；模块少时面板自动变窄（3 个模块 320pt，4 个 345pt，5 个 380pt）
- 中英文切换
- 计价货币：人民币 / 美元（按可改汇率换算，内部仍存人民币）
- DeepSeek 模型价格：可直接改 Flash / Pro 的空闲与高峰价；也可粘贴价格页网址自动识别（支持官方 .md / HTML 表格，识别失败仍可手填）
- 应用图标：复古版画（默认）/ 水彩治愈 / 经典
- 状态圆环配色：经典（系统绿/橙/红）/ 柔和（默认，方案 A）/ 浅色（方案 B），设置内实时预览三色
- 启动时检查更新、手动检查更新（GitHub Releases `0xTack/TokenPeek`）
- 底部「更新日志」和「反馈」
- iCloud 备份

### iCloud 备份
- 设置 →「iCloud 备份」
- 立即备份 / 从最近备份恢复 / 打开备份文件夹 / 每天自动备份（默认关闭）
- 备份内容：官方账号、手动花费、本地来源配置与 jsonl、价格缓存与自定义价格、界面设置
- 官方 Token 使用 AES-GCM 加密为 `official-accounts.enc`
- 密钥只在本机：`~/Library/Application Support/DeepSeekCost/backup.key`（600）
- 备份位置：`~/Library/Mobile Documents/com~apple~CloudDocs/TokenPeek/backups/`
- 换机没有本机密钥时 Token 不恢复，需要重新登录
- CLI：`--backup` / `--backup-list` / `--restore-latest`

### 其他
- 命中率行左侧小号「（预测 ¥x.xx/百万）」，按当前命中率估算输入均价
- 趋势图：单条平滑总用量曲线，跟随「近 7 天 / 本月 / 近 30 天」；选「今日」时隐藏；无模式切换、无每日柱状图
- 我的用量：可在「数字 / 柱状图」之间切换；只能在设置里选，面板上不再有切换图标
- 两个下拉统一自绘：单箭头、无边框、低对比填充、hover 高亮
- 选中态蓝色改为淡蓝
- 全局 UI 文案末尾不再加句号
- 「设置」菜单项去掉省略号和自动齿轮图标
- 「退出」只写退出
- 右键菜单改为与系统外观一致的自绘面板：浅色/深色跟随系统，半透明材质，左边缘比图标向左约 12pt 向右展开（和系统菜单一致），带淡入淡出

## 构建 / 打包

```bash
cd "/Users/xa/Documents/Default Project/DeepSeekCost"

# 本机安装（arm64 / macOS 14+）
./build.sh

# 打包并自动 +1 次版本号
./package.sh

# 重打同一版
SKIP_VERSION_BUMP=1 ./package.sh

# Intel x86_64 / macOS 13+
./package-intel13.sh
```

注意：

- `Info.plist` 当前 1.5 / Build 6
- `AppIcon.icns` 默认复古猫；`AppIcon-retro.png` / `AppIcon-watercolor.png` / `AppIcon-classic.icns` 供运行时切换
- 本机只有 CommandLineTools，没有完整 Xcode
- macOS 27.2 SDK 的 `@State` 是宏，CLT 缺 SwiftUIMacros；构建脚本检测到 `MacOSX26.5.sdk` 时会自动加 `-sdk`，不要删这段回退逻辑
- 打包产物会自动复制到桌面

## 数据文件

`~/Library/Application Support/DeepSeekCost/`：

- `official-accounts.json`（600，含 Token）
- `manual-costs.json`
- `local-sources.json`
- `sources/*.jsonl`
- `pricing.json`
- `pricing-overrides.json`（设置里改过 / 网址识别出的模型价格）
- `backup.key`（600，iCloud 备份加密密钥）
- `platform-token`（旧版遗留）

## 已知问题 / 未验证

1. **iCloud 备份 UI 未逐项点击验证**：备份写入、加密、恢复已用 CLI 实测通过；设置页按钮未完整人工点测
2. **Intel macOS 13 包未实机验证**
3. **DeepSeek API Key 不能读用量**：`sk-` 只能查余额；读用量必须网页 Token。API Key 模式未实现
4. **iCloud 备份 Token 换机不可恢复**：密钥只在本机；换机需重新登录
5. **官方「全部」仍是近 30 天**：接口单次 31 天上限
6. **OpenCode 与官方可能重叠**：环形图已排除 OpenCode 的 DeepSeek 部分；主面板按当前来源显示
7. **应用图标缓存**：Finder/Dock 可能缓存旧图，`killall Dock` 或重开 App
8. **v1.5 已发布（2026-11-02）**：GitHub Release 和 Pages 已更新；Release 里的源码归档仍指向旧 main 提交，源码尚未提交到 main
9. **中英文本地化不完整**：主要界面已翻译，部分帮助文案仍为中文
10. **价格网址识别依赖表格结构**：官方价格页（.md / HTML）可识别；结构差异较大的页面识别不到时会保留原价格，仍可手动填写。本轮只用本地样例验证，未对真实官网联网测过
11. **ad-hoc 签名**：无 Developer ID / 公证
12. **没有自定义 HTTP API 表单**：其他厂商目前走本地来源脚本 + AI 提示词
13. **菜单按系统菜单方式定位**：左边缘比状态栏图标向左约 12pt，向右展开；右边放不下时整体左移。已用 LuLu 的原生菜单实测对齐
14. **右键菜单跟随系统浅色/深色，不跟 App 自己的外观设置**：这是为了和其他软件一致；如果要求跟 App，把 `showMenu` 里的 `systemAppearance` 换回 App 外观
15. **状态栏图标本身的位置由系统决定**：App 已设置 `autosaveName`，⌘-拖动图标后位置会被记住；但 App 不能强制把图标排到某个固定位置
16. **「本月」在月初趋势点很少**：11 月 1 日选「本月」只有今天一个点（会画成居中的小圆点），切「近 7 天 / 全部」才完整
17. **官方账号区仍只显示数字**：官方接口只有按 Key 的区间汇总，没有逐模型数据；「我的用量」柱状图只对 OpenCode / 自定义 / 本地来源生效
18. **自定义右键菜单没有原生键盘导航**：⌘, / ⌘Q 走 App 主菜单仍可用

## 建议下一步

1. 人工点测右键菜单：系统浅色/深色、半透明、左边缘比图标向左约 12pt 向右展开、淡入淡出
2. 人工点测趋势图：近 7 天/本月/全部、今日隐藏、30 天标签、浅色/深色下线条对比
3. 人工点测「我的用量」数字/柱状图：设置里的选项能正常切换面板显示
4. 人工点测设置页的 iCloud 备份 / 恢复 / 自动备份
5. 有网络时用官方价格页真实网址测一次「识别」，确认 HTML 表格版本能解析
6. 如用户需要，增加 DeepSeek「API Key（仅余额）」模式
7. 如用户需要，增加通用「自定义 API」表单（URL / Header / JSON 字段映射）
8. 补全英文文案
9. Intel 包在真实 macOS 13 上验证；把 1.5 源码提交并推送到 main
10. 如需完全免 Gatekeeper 提示，申请 Developer ID 并公证

## 相关文档

- `docs/自定义来源接入说明.md`
- `README.md`（部分旧内容仍停留在 1.1，新增内容看本文优先）
