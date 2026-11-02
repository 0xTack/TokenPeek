window.DEEPSEEK_RELEASE = {
  "version": "1.6",
  "date": "2026-11-02",
  "versions": {
    "mac": "1.6",
    "windows": "1.3"
  },
  "base": "https://github.com/0xTack/TokenPeek/releases/download/v1.6/",
  "downloads": [
    {
      "id": "mac-arm64",
      "platform": "macOS",
      "name": "Apple Silicon",
      "arch": "arm64",
      "version": "1.6",
      "min": "macOS 14 Sonoma 或更高",
      "recommended": true,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.6-AppleSilicon.dmg",
          "size": "4.2 MB",
          "sha256": "dbf3cfd1a7985ed8b5a02b3c9c6cd5f370fdd27f5ada4736bae26159ed9d3ab4"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.6-AppleSilicon.zip",
          "size": "3.8 MB",
          "sha256": "52d11fe04ee0c5bc6509769bbfba3403e5c07233642c28b0da913833743d8580"
        }
      ]
    },
    {
      "id": "mac-intel",
      "platform": "macOS",
      "name": "Intel",
      "arch": "x86_64",
      "version": "1.6",
      "min": "macOS 13 Ventura 或更高",
      "recommended": false,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.6-Intel.dmg",
          "size": "4.3 MB",
          "sha256": "9e854599b05e9bea186faf15335a7191af56305b2141e0d30d5af6cbfaf101c7"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.6-Intel.zip",
          "size": "3.9 MB",
          "sha256": "810f3eb1b35fdd52db2e6b5b22ffd287786c30030bd57d0ec29835ab9aa9c050"
        }
      ]
    },
    {
      "id": "windows-x64",
      "platform": "Windows",
      "name": "Windows 11",
      "arch": "x64",
      "version": "1.3",
      "min": "Windows 11 / Windows 10 21H2+",
      "recommended": false,
      "files": [
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "DeepSeekDashboard-1.3-Windows-x64.zip",
          "size": "152.7 MB",
          "sha256": "61dd5a917675d0b703c1bbcd5394096c526b397da972fc2e2114ab666a7b538a"
        }
      ]
    }
  ],
  "history": [
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
