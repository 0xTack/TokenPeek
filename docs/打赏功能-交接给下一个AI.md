# 打赏功能 · 交接文档（给下一个 AI）

## 0. 交接摘要

- 项目：`/Users/xa/Documents/Default Project/DeepSeekCost/`
- 主程序：`main.swift`（单文件）
- 当前版本：1.5 / Build 6，未发布；已安装 `/Applications/TokenPeek.app`
- 本文覆盖：`👏 有你真好` 打赏窗口的入口、界面、彩蛋、音效、二维码、打包
- 当前状态：已实现并安装，`swiftc` 与 `--self-test` 通过
- 待办：爱发电主页已提交实名认证（2026-11-02 提交，预计 2 个工作日）；通过前公开页显示「未认证创作者」，Tack 的名字/简介/头像不显示
- Windows 版（`windows/`）仍是旧的微信赞赏码，本轮的改动尚未同步过去

## 1. 需求 / 行为规范

### 1.1 定位

- 免费软件的自愿赞赏，**不换取任何功能或服务，不支持退款**
- 不启动弹窗、不挡主流程；只有一个菜单入口
- 双渠道：
  - 主入口：爱发电按钮 `https://afdian.com/a/tack123`
  - 次入口：微信赞赏码（可选，图片缺失时自动隐藏）
- 不接支付回调，**不假装知道谁付了钱**

### 1.2 入口

- 菜单栏右键菜单：`👏 有你真好`，在「检查更新」下方，上方一条分隔线，下方分隔线后是「退出」
- CLI：`--donation`（启动后 0.7s 自动打开，用于调试）
- 窗口标题：`有你真好` / `So glad to have you`

### 1.3 窗口行为

- 独立窗口（`titled + closable`），不随关闭释放，重复打开复用
- 打开顺序：`layoutSubtreeIfNeeded` → `setContentSize(fittingSize)` → 居中
  - 顺序不能反，否则会以旧尺寸居中后向右下长，偏 10–15pt
- 居中在鼠标所在屏幕的 `visibleFrame`，并限制在可视区域内
- 不阻塞主界面；Esc 或「关闭」按钮关闭

### 1.4 界面参数（当前）

| 元素 | 参数 |
|---|---|
| 窗口宽 | 340pt |
| 内边距 | 18pt |
| 纵向间距 | 10pt |
| 顶部吹捧文案 | 14pt medium，最多 300pt 宽 |
| 爱发电按钮 | 紫色胶囊，白字 12pt semibold，内边距 20 / 9 |
| 分隔文案 | `或 微信扫码` / `or scan WeChat`，9pt |
| 二维码 | 120 × 120pt，圆角 8pt；按深色内容自动裁正居中 |
| 消息条预留 | 26pt（默认空，彩蛋时显示玻璃条） |
| 声明 | 9pt secondary，居中 |
| 关闭按钮 | 默认按钮，Esc 快捷键 |

从上到下：

1. 随机吹捧文案（10 条中英）
2. `去爱发电支持` 按钮
3. `或 微信扫码` 分隔线（仅当二维码存在）
4. 微信赞赏码（仅当图片存在）
5. 26pt 消息条（默认空；彩蛋时出现）
6. 声明：`自愿赞赏 · 不换取任何功能或服务 · 不支持退款`
7. `关闭`

注意：二维码下面**不要**再放「微信扫码赞赏」文字。

### 1.5 彩蛋时序

- `0s`：随机显示一条吹捧文案
- `1s`：播放合成欢呼音效 + 玻璃条「天气从未如此明媚」3 秒
- `10s` 未关闭：「你这么好看，在犹豫什么」4 秒
- 每个彩蛋每次打开只触发一次
- 关闭窗口时取消未触发的任务
- 消息淡入 0.25s / 淡出 0.3s

### 1.6 音效

- `AVAudioEngine` 实时合成，不需要音频资源
- C5–E5–G5–C6 琶音（0 / 0.1 / 0.2 / 0.3s）+ 0.42s 起的三音和弦，总长 1.6s
- 主音量 0.4，单样本限制 ±0.35
- 失败回退 `NSSound(named: "Glass")`
- 2 秒后自动停止并释放

### 1.7 二维码处理

- 资源：`donation-qr.png`（620 × 620），默认不进仓库，打包时注入
- 原图内容偏右 16px、偏上 19px（相对 620 中心）
- `DonationQRCode` 运行时扫描深色像素找二维码本体包围盒，忽略金色徽章，裁成以本体为中心的正方形，保留约 1/12 边长的白边
- 换任何一张带白底的赞赏码图片都会自动居中
- 找不到图片时隐藏二维码和「或 微信扫码」分隔线

## 2. 完整代码

### 2.1 DonationView（界面 + 彩蛋）

```swift
struct DonationView: View {
    private static let compliments: [(zh: String, en: String)] = [
        ("你真好看", "You look great"),
        ("今天的你，比昨天更好看", "You look even better today than yesterday"),
        ("你的品味，真的很在线", "Your taste is impeccable"),
        ("你一笑，天气都变好了", "Your smile makes the weather better"),
        ("你认真生活的样子，很迷人", "The way you live is charming"),
        ("你值得所有温柔和好运", "You deserve all the kindness and luck"),
        ("你一来，整个房间都亮了", "The room lights up when you walk in"),
        ("你的眼光，从来不会让人失望", "Your taste never disappoints"),
        ("你不仅好看，还很有眼光", "You're not just good-looking; you have great taste"),
        ("有你在，平凡的一天也会发光", "With you around, an ordinary day shines"),
    ]

    @State private var complimentIndex = Int.random(in: 0..<10)
    @State private var celebrationTask: DispatchWorkItem?
    @State private var nudgeTask: DispatchWorkItem?
    @State private var activeMessage: String?
    @State private var didScheduleCelebration = false
    @State private var didScheduleNudge = false

    var body: some View {
        VStack(spacing: 10) {
            Text(L.t(Self.compliments[complimentIndex].zh, Self.compliments[complimentIndex].en))
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.top, 2)

            Button {
                if let url = URL(string: "https://afdian.com/a/tack123") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "heart.fill")
                    Text(L.t("去爱发电支持", "Support on Afdian"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            if DonationQRCode.hasImage {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 0.5)
                    Text(L.t("或 微信扫码", "or scan WeChat"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 0.5)
                }

                DonationQRCode(size: 120)
            }

            ZStack {
                if let message = activeMessage {
                    HStack(spacing: 8) {
                        Text("💖")
                            .font(.system(size: 14))
                        Text(message)
                            .font(.system(size: 10, weight: .medium))
                        Text("✨")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        GlassBackground(alpha: 0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: 26)
            .padding(.top, DonationQRCode.hasImage ? -24 : 0)

            Text(L.t(
                "自愿赞赏 · 不换取任何功能或服务 · 不支持退款",
                "Voluntary tip · No features or services in return · Non-refundable"
            ))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button(L.t("关闭", "Close")) { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            complimentIndex = Int.random(in: 0..<Self.compliments.count)
            scheduleCelebrationOnce()
            scheduleNudgeOnce()
        }
        .onDisappear {
            celebrationTask?.cancel()
            celebrationTask = nil
            nudgeTask?.cancel()
            nudgeTask = nil
        }
    }

    private func scheduleCelebrationOnce() {
        guard !didScheduleCelebration else { return }
        didScheduleCelebration = true

        let task = DispatchWorkItem {
            CelebrationSound.play()
            showMessage(L.t("天气从未如此明媚", "The weather has never been so bright"), duration: 3.0)
        }
        celebrationTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func scheduleNudgeOnce() {
        guard !didScheduleNudge else { return }
        didScheduleNudge = true

        let task = DispatchWorkItem {
            showMessage(L.t("你这么好看，在犹豫什么", "You look so great. What are you waiting for?"), duration: 4.0)
        }
        nudgeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: task)
    }

    private func showMessage(_ text: String, duration: TimeInterval) {
        withAnimation(.easeOut(duration: 0.25)) {
            activeMessage = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if activeMessage == text {
                withAnimation(.easeOut(duration: 0.3)) {
                    activeMessage = nil
                }
            }
        }
    }

}
```

### 2.2 DonationQRCode（自动裁正居中）

```swift
private struct DonationQRCode: View {
    let size: CGFloat

    private static var cache: NSImage?

    static var centeredImage: NSImage? {
        if let cache { return cache }
        guard let original = loadOriginal(),
              let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return original }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 用深色像素找二维码本体的包围盒；金色徽章不参与，避免把视觉重心带偏。
        var minX = w, maxX = 0, minY = h, maxY = 0
        var found = false
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bytesPerRow + x * 4
                guard data[i + 3] > 16 else { continue }
                if max(data[i], data[i + 1], data[i + 2]) < 160 {
                    found = true
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard found else { return original }

        let centerX = CGFloat(minX + maxX) / 2
        let centerY = CGFloat(minY + maxY) / 2
        let contentSide = CGFloat(max(maxX - minX, maxY - minY) + 1)
        let margin = max(16, contentSide / 12)
        let side = min(CGFloat(min(w, h)), contentSide + margin * 2)

        var rect = CGRect(
            x: centerX - side / 2,
            y: centerY - side / 2,
            width: side,
            height: side
        )
        rect.origin.x = max(0, min(rect.origin.x, CGFloat(w) - side))
        rect.origin.y = max(0, min(rect.origin.y, CGFloat(h) - side))

        guard let cropped = cg.cropping(to: rect) else { return original }
        let result = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        cache = result
        return result
    }

    static var hasImage: Bool { centeredImage != nil }

    private static func loadOriginal() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "donation-qr", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let image = Self.centeredImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
```

### 2.3 CelebrationSound（合成欢呼音效）

```swift
enum CelebrationSound {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?

    static func play() {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * 1.6)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        let frames = Int(buffer.frameLength)
        let notes: [(onset: Double, frequency: Double)] = [
            (0.00, 523.25),
            (0.10, 659.25),
            (0.20, 783.99),
            (0.30, 1046.50),
        ]

        for index in 0..<frames {
            let time = Double(index) / sampleRate
            var sample = 0.0

            for note in notes {
                let delta = time - note.onset
                guard delta >= 0, delta < 0.5 else { continue }
                let attack = min(1.0, delta * 80)
                let decay = exp(-delta * 7)
                sample += sin(2 * .pi * note.frequency * delta) * attack * decay * 0.16
            }

            if time >= 0.42, time < 1.5 {
                let delta = time - 0.42
                let attack = min(1.0, delta * 50)
                let decay = exp(-delta * 3.2)
                let chord = (
                    sin(2 * .pi * 523.25 * delta)
                    + sin(2 * .pi * 659.25 * delta)
                    + sin(2 * .pi * 783.99 * delta)
                ) / 3
                sample += chord * attack * decay * 0.09
            }

            channel[index] = Float(max(-0.35, min(0.35, sample)))
        }

        let audioEngine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.4

        do {
            try audioEngine.start()
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            node.play()
        } catch {
            NSSound(named: "Glass")?.play()
        }

        engine = audioEngine
        player = node

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            node.stop()
            audioEngine.stop()
            if player === node { player = nil }
            if engine === audioEngine { engine = nil }
        }
    }
}
```

### 2.4 GlassBackground（消息条玻璃背景）

```swift
private struct GlassBackground: NSViewRepresentable {
    var alpha: CGFloat = 0.52

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = alpha
    }
}
```

### 2.5 窗口创建与居中

```swift
    private func showDonation() {
        let host = NSHostingController(rootView: ThemedRoot { DonationView() })
        let window: NSWindow

        if let existing = donationWindow {
            existing.contentViewController = host
            window = existing
        } else {
            let created = NSWindow(contentViewController: host)
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            donationWindow = created
            window = created
        }

        host.view.layoutSubtreeIfNeeded()
        window.title = L.t("有你真好", "So glad to have you")
        window.setContentSize(host.view.fittingSize)
        if !window.isVisible {
            centerWindow(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

```swift
    /// 在鼠标所在屏幕的可视区域居中，避免多显示器时跑到另一块屏或超出边缘。
    private func centerWindow(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
```

### 2.6 入口接线

右键菜单行（位于「检查更新」和「退出」之间）：

```swift
            MenuRow(title: L.t("检查更新", "Check for updates"), action: onCheckUpdates)
            MenuRow(
                title: L.t("有你真好", "So glad to have you"),
                emoji: "👏",
                action: onDonation
            )
            Divider().padding(.vertical, 4)
```

`StatusMenuView` 的 onDonation 接线：

```swift
            onCheckUpdates: { [weak self] in
                self?.closeStatusMenu()
                self?.checkForUpdates()
            },
            onDonation: { [weak self] in
                self?.closeStatusMenu()
                self?.showDonation()
            },
```

`--donation` 启动参数：

```swift
        if ProcessInfo.processInfo.arguments.contains("--donation") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.showDonation()
            }
        }
```

## 3. 资源与打包

- `donation-qr.png` 620×620，放在项目根目录，不提交仓库
- macOS：`build.sh` / `package.sh` / `package-intel13.sh` 复制到 `Contents/Resources/`
- Windows：`windows/build-windows.sh` 复制到 `windows/assets/`
- 缺少文件时只显示爱发电按钮，不留空行
- 爱发电链接当前硬编码为 `https://afdian.com/a/tack123`

## 4. 改另一个软件时

- 入口放在「关于 / 设置」或菜单里，**不要启动弹窗**
- 打开系统浏览器到爱发电主页
- 二维码可选；展示前检查资源，缺失就隐藏整块
- 文案和声明照抄，不要写「购买 / 会员 / 解锁」
- 彩蛋用定时器；窗口关闭时清理全部定时器
- 深色模式单独适配文字和玻璃背景
- 建议尺寸：宽 340，二维码 120，声明 9pt
- 不要做「已打赏」状态，也不要根据支付结果写感谢文案

## 5. 验收清单

- [ ] 右键菜单入口在「检查更新」下方，带 👏
- [ ] 打开窗口不阻塞、居中、Esc 可关
- [ ] 每次打开随机一条吹捧文案
- [ ] 爱发电按钮能打开正确链接
- [ ] 有二维码时显示；删掉图片后自动隐藏且不留空行
- [ ] 二维码本体在窗口里居中（不是图片方框居中）
- [ ] 1s / 10s 彩蛋各只触发一次，关闭即取消
- [ ] 浅色 / 深色下文字可读
- [ ] 二维码下没有「微信扫码赞赏」文字

## 6. 已知问题 / 注意

1. 爱发电主页认证审核中；通过前公开页显示「未认证创作者」
2. 爱发电方案按月计费（页面显示 `/月`），不是一次性
3. 微信赞赏码有风控、限额、海外不可用等问题；不要用个人码做经营收款
4. 赞赏属于个人所得，金额大时注意申报
5. Windows 版打赏页尚未同步为爱发电 + 微信双入口
6. 二维码自动裁正会减少原图留白；当前保留约 1/12 边长，仍满足扫码
