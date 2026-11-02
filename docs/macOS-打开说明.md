# macOS 打开说明

TokenPeek 的 macOS 安装包使用 **ad-hoc 签名**，没有 Apple Developer ID，也没有做公证。因此第一次打开时，macOS 的 Gatekeeper 可能会拦截。

**这不是病毒，也不会把任何数据上传。** 代码是 MIT 开源的，可以自行审查或编译。

如果系统提示「已损坏，应移到废纸篓」，**先不要移到废纸篓**。按下面的步骤处理即可。

---

## 情况 1：提示「无法打开，因为无法验证开发者」

任选一种方式：

### 方式 A：右键打开

1. 在「应用程序」里找到 **TokenPeek**
2. **右键**（或按住 Control 点按）→ 选择「打开」
3. 在弹窗里再点「打开」

### 方式 B：系统设置里放行

1. 先双击一次 App，让系统弹出拦截提示
2. 打开 **系统设置 → 隐私与安全性**
3. 在页面下方找到「已阻止使用 TokenPeek」
4. 点 **仍要打开**
5. 输入开机密码或 Touch ID

### 方式 C：终端移除隔离标记

```bash
xattr -dr com.apple.quarantine "/Applications/TokenPeek.app"
open "/Applications/TokenPeek.app"
```

---

## 情况 2：提示「已损坏，应移到废纸篓」

这是下载隔离标记导致的常见提示，不代表文件真的损坏。

1. **不要点「移到废纸篓」**
2. 如果已经移进废纸篓，把它从废纸篓拖回「应用程序」
3. 打开「终端」，执行：

```bash
xattr -cr "/Applications/TokenPeek.app"
open "/Applications/TokenPeek.app"
```

4. 如果仍然提示，再按「情况 1」的方式右键 → 打开

---

## 情况 3：提示「需要 Rosetta」或架构不匹配

- **Apple Silicon（M1 / M2 / M3 / M4）**：下载文件名带 `AppleSilicon` 的版本
- **Intel Mac**：下载文件名带 `Intel` 的版本
- Intel 版在 Apple Silicon 上可以通过 Rosetta 2 运行，但建议优先用原生 Apple Silicon 版
- Apple Silicon 版不能在 Intel Mac 上运行

---

## 校验安装包

如果担心下载不完整，可以校验 SHA-256：

```bash
shasum -a 256 ~/Downloads/TokenPeek-1.5-AppleSilicon.dmg
```

把输出与发布页或 Release 页面里的校验值对比。一致就说明文件完整。

---

## 为什么不做签名和公证

- Apple Developer ID 年费 99 美元，公证流程也需要额外配置
- 这是一个免费、开源的小工具
- 源码公开，可以自行编译：`./build.sh`
- 官方构建使用 ad-hoc 签名，功能完整，只是首次打开需要手动放行

---

## 卸载

```bash
pkill -f "TokenPeek.app/Contents/MacOS/DeepSeekCost"
rm -rf "/Applications/TokenPeek.app"
```

可选删除本机数据：

```bash
rm -rf "$HOME/Library/Application Support/DeepSeekCost"
```

---

如果以上方法都不行，请在 GitHub 仓库提 Issue，并附上：

- macOS 版本
- 芯片类型（Apple Silicon / Intel）
- 完整报错截图
- `xattr -l "/Applications/TokenPeek.app"` 的输出
