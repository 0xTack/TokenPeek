window.DEEPSEEK_RELEASE = {
  "version": "1.5",
  "date": "2026-11-02",
  "versions": {
    "mac": "1.5",
    "windows": "1.3"
  },
  "base": "https://github.com/0xTack/TokenPeek/releases/download/v1.5/",
  "downloads": [
    {
      "id": "mac-arm64",
      "platform": "macOS",
      "name": "Apple Silicon",
      "arch": "arm64",
      "version": "1.5",
      "min": "macOS 14 Sonoma 或更高",
      "recommended": true,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.5-AppleSilicon.dmg",
          "size": "4.2 MB",
          "sha256": "31c6bb3ea99f9973bdf8550e2a2644fac36e5ec7aac8ae8f22b142e32334b644"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.5-AppleSilicon.zip",
          "size": "3.7 MB",
          "sha256": "ace6401f8c6b3faee49333c7f2081f51c6a123d08df410b0c1d5949c6906db1c"
        }
      ]
    },
    {
      "id": "mac-intel",
      "platform": "macOS",
      "name": "Intel",
      "arch": "x86_64",
      "version": "1.5",
      "min": "macOS 13 Ventura 或更高",
      "recommended": false,
      "files": [
        {
          "type": "dmg",
          "label": "下载 .dmg",
          "file": "TokenPeek-1.5-Intel.dmg",
          "size": "4.3 MB",
          "sha256": "3e4094a77788e961e5368b524f1db117cb6cdb06f60be935f1bdfa66c7bcc9da"
        },
        {
          "type": "zip",
          "label": "下载 .zip",
          "file": "TokenPeek-1.5-Intel.zip",
          "size": "3.8 MB",
          "sha256": "0df5ccd841fdc309e04e18282816b415ef4c71e4c4bfd40763cf7378136b45d4"
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
