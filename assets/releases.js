window.DEEPSEEK_RELEASE = {
  "version": "1.7",
  "date": "2026-11-03",
  "versions": {
    "mac": "1.7"
  },
  "base": "https://github.com/0xTack/TokenPeek/releases/download/v1.7/",
  "downloads": [
    {
      "id": "mac-arm64",
      "platform": "macOS",
      "name": "Apple Silicon",
      "arch": "arm64",
      "version": "1.7",
      "min": "macOS 14 Sonoma 或更高",
      "recommended": true,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.7-AppleSilicon.dmg",
          "size": "4.2 MB",
          "sha256": "9516b702fa14074a6efbe2e4dca5d0c18c74200023f40fd7ddf5e99fe6bf0f92"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.7-AppleSilicon.zip",
          "size": "3.9 MB",
          "sha256": "66d13265027abe8e708b71078713a72582c21b85aaa2c074180573cdc5b86a8a"
        }
      ]
    },
    {
      "id": "mac-intel",
      "platform": "macOS",
      "name": "Intel",
      "arch": "x86_64",
      "version": "1.7",
      "min": "macOS 13 Ventura 或更高",
      "recommended": false,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.7-Intel.dmg",
          "size": "4.3 MB",
          "sha256": "3dd9e033cc124a01bc1f3ffd54b92a0230a4e7fa2cf7e4d3bcba0ee1a3c395b4"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.7-Intel.zip",
          "size": "3.9 MB",
          "sha256": "73d316e09e72344bd210029c803d307cc96ca8594a35438e31e5966bbfe4283d"
        }
      ]
    }
  ],
  "history": [
    {
      "version": "1.7",
      "date": "2026-11-03",
      "notes": [
        "启动时不再自动弹出主窗口，只在菜单栏驻留；需要时点右键菜单「打开主窗口」",
        "「我的用量」在没有数据时保留完整版面：显示零值和空状态，可直接「接入来源」或「刷新」，面板不再塌缩变形"
      ]
    },
    {
      "version": "1.6",
      "date": "2026-11-02",
      "notes": [
        "新增「订阅监控」：任何返回 JSON 的接口都能接入，自动识别字段，显示剩余或已用的百分比",
        "订阅支持胶囊 / 柱状图两种显示，设置里可切换",
        "面板里订阅与余额合成一块，只留一个刷新按钮，同时刷新两项",
        "「充值」不再常驻，鼠标移到余额行才出现",
        "设置里合并成「订阅与花费」，订阅和手动花费放在一起",
        "修复显示切换后不生效的问题"
      ]
    },
    {
      "version": "1.5",
      "date": "2026-11-02",
      "notes": [
        "液态玻璃面板，浅色 / 深色更统一",
        "状态圆环配色：经典 / 柔和 / 浅色，设置内实时预览",
        "多账号总花费：已登录账号的花费全部计入",
        "趋势图简化为一条平滑总用量曲线",
        "右键面板对齐系统菜单，窗口居中修正",
        "价格页网址识别、iCloud 加密备份、手动花费"
      ]
    },
    {
      "version": "1.3",
      "date": "2026-10-31",
      "notes": [
        "Windows 版新增官方 API Key 余额：绑定后在面板直接显示余额、充值余额与赠送余额",
        "自动发现 Wetokens、Claude Code、Codex、Gemini CLI 等本地用量，可在数据源里切换",
        "新增「本地接口」：支持本地 JSON / JSONL 文件、目录，或内网 HTTP 地址",
        "新增本地收集接口：监听 127.0.0.1:47123，其他脚本可 POST /usage 上报",
        "macOS 版保持 1.1，下载卡片中单独标注版本"
      ]
    },
    {
      "version": "1.1",
      "date": "2026-10-31",
      "notes": [
        "「我的用量」同时显示今日 / 近 7 天 / 本月 / 全部，并新增统计区间切换",
        "本月改为自然月统计，每月 1 日重新开始，不再按滚动 30 天",
        "排行与缓存命中率跟随所选区间；官方模式「全部」如实标注为近 30 天",
        "新增 Windows 11 版（Electron 绿色版），与 macOS 版功能对齐",
        "macOS 拆分为 Apple Silicon 与 Intel 两个原生安装包"
      ]
    },
    {
      "version": "1.0",
      "date": "2026-10-31",
      "notes": [
        "首个版本：菜单栏时段状态、官方价格、OpenCode 用量、余额与缓存命中率",
        "支持官方账户按 API Key 查看、自定义 App 上报、开机自启"
      ]
    }
  ]
};
