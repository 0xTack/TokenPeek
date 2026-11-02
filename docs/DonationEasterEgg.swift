import AppKit
import AVFoundation
import SwiftUI

/// 「有你真好」赞赏页彩蛋
///
/// 用法：
/// ```swift
/// let host = NSHostingController(
///     rootView: DonationRewardView(
///         qrImage: NSImage(named: "donation-qr"),
///         onClose: { NSApp.keyWindow?.close() }
///     )
/// )
/// ```
///
/// 时间线：
/// - 打开后 1 秒：播放短促上行音效，并在二维码下方显示「天气从未如此明媚」3 秒
/// - 打开后 10 秒仍未关闭：再显示「你这么好看，在犹豫什么」4 秒
/// - 每次打开只触发一次，关闭窗口会取消未触发的任务
struct DonationRewardView: View {
    let qrImage: NSImage?
    var qrSize: CGFloat = 293
    var panelWidth: CGFloat = 400
    var onClose: () -> Void = {}

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
        VStack(spacing: 14) {
            Text(Self.compliments[complimentIndex].zh)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 2)

            qrCode

            ZStack {
                if let message = activeMessage {
                    HStack(spacing: 8) {
                        Text("💖")
                            .font(.system(size: 18))
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                        Text("✨")
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        GlassPanel(alpha: 0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    Text("微信赞赏码")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 40)

            Text("自愿赞赏 · 不换取任何功能或服务 · 不支持退款")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: panelWidth)
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

    @ViewBuilder
    private var qrCode: some View {
        if let qrImage {
            Image(nsImage: qrImage)
                .resizable()
                .interpolation(.high)
                .frame(width: qrSize, height: qrSize)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .interpolation(.high)
                .frame(width: qrSize, height: qrSize)
                .foregroundStyle(.secondary)
        }
    }

    private func scheduleCelebrationOnce() {
        guard !didScheduleCelebration else { return }
        didScheduleCelebration = true

        let task = DispatchWorkItem {
            CelebrationSound.play()
            showMessage("天气从未如此明媚", duration: 3.0)
        }
        celebrationTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func scheduleNudgeOnce() {
        guard !didScheduleNudge else { return }
        didScheduleNudge = true

        let task = DispatchWorkItem {
            showMessage("你这么好看，在犹豫什么", duration: 4.0)
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

// MARK: - 玻璃条

struct GlassPanel: NSViewRepresentable {
    var alpha: CGFloat = 0.5

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

// MARK: - 欢呼音效

/// 纯代码合成的短促上行音 + 柔和和弦，不依赖任何音频文件
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
