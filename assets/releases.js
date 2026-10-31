window.DEEPSEEK_RELEASE = {
  "version": "1.3",
  "date": "2026-10-31",
  "versions": {
    "mac": "1.1",
    "windows": "1.3"
  },
  "base": "https://github.com/xiaoan223/deepseek-dashboard/releases/download/v1.3/",
  "downloads": [
    {
      "id": "mac-arm64",
      "platform": "macOS",
      "name": "Apple Silicon",
      "arch": "arm64",
      "version": "1.1",
      "min": "macOS 14 Sonoma 或更高",
      "recommended": true,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "DeepSeek仪表盘-1.1-AppleSilicon.dmg",
          "size": "1.3 MB",
          "sha256": "06c61186a27e988a778390a0b2fef452d2e76d268e94c4689a0b20908b2dfe34"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "DeepSeek仪表盘-1.1-AppleSilicon.zip",
          "size": "1008 KB",
          "sha256": "26466f09f1d318dbc129a8a63e50b6ac3e9f52cb8692f91fb4a4a2bc3c0f9cf0"
        }
      ]
    },
    {
      "id": "mac-intel",
      "platform": "macOS",
      "name": "Intel",
      "arch": "x86_64",
      "version": "1.1",
      "min": "macOS 13 Ventura 或更高",
      "recommended": false,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "DeepSeek仪表盘-1.1-Intel.dmg",
          "size": "1.4 MB",
          "sha256": "4b6728d5c619f0edc5a388092e32229710291fb6919cc491d3358da3bc7376b5"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "DeepSeek仪表盘-1.1-Intel.zip",
          "size": "1.0 MB",
          "sha256": "103a153877057d45f1ebadae44afefa7b817c779ccd2e96c4a68b8eb9ab2d702"
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
