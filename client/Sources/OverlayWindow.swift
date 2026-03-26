import SwiftUI
import AppKit

/// 悬浮窗口的显示状态
enum OverlayState: Equatable {
    case listening
    case processing
}

/// 悬浮窗口控制器 - 显示录音状态
class OverlayWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayView>?
    private var viewModel = OverlayViewModel()
    private var sizeObserver: NSObjectProtocol?

    init() {
        setupWindow()
    }

    private func setupWindow() {
        let contentView = OverlayView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: contentView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        guard let window = window else { return }

        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isMovableByWindowBackground = false
        window.hasShadow = true

        sizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostingView,
            queue: .main
        ) { [weak self] _ in
            self?.centerWindow()
        }
        hostingView?.postsFrameChangedNotifications = true

        positionWindow()
    }

    private func positionWindow() {
        guard let window = window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        let y = screenFrame.maxY - window.frame.height - 60

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func centerWindow() {
        guard let window = window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
    }

    func show() {
        viewModel.reset()
        viewModel.state = .listening
        viewModel.startAnimation()
        positionWindow()
        window?.orderFront(nil)
    }

    func updateRecognizedText(_ stableText: String, unfixedText: String? = nil) {
        viewModel.stableText = stableText
        viewModel.unfixedText = unfixedText ?? ""
    }

    func updateAudioLevel(_ level: Float) {
        viewModel.audioLevel = CGFloat(level)
    }

    func showProcessing() {
        viewModel.state = .processing
    }

    func hide() {
        viewModel.stopAnimation()
        window?.orderOut(nil)
    }
}

/// 悬浮窗口视图模型
class OverlayViewModel: ObservableObject {
    @Published var animationPhase: CGFloat = 0
    @Published var stableText: String = ""
    @Published var unfixedText: String = ""
    @Published var state: OverlayState = .listening
    @Published var audioLevel: CGFloat = 0

    var hasText: Bool {
        !stableText.isEmpty || !unfixedText.isEmpty
    }

    private var animationTimer: Timer?

    func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.animationPhase += 0.15
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func reset() {
        stableText = ""
        unfixedText = ""
        audioLevel = 0
        state = .listening
    }
}

/// 悬浮窗口视图 - 自适应宽度与滚动效果
struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private let maxWidth: CGFloat = 400
    private let maxLines: Int = 5
    private let lineHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            statusIndicator

            if viewModel.hasText {
                textContentView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 130, maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
        .animation(.easeInOut(duration: 0.15), value: viewModel.animationPhase)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.state {
        case .listening:
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 3, height: waveHeight(for: index))
                    }
                }
                .frame(width: 30, height: 18)

                Text("正在聆听...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)

                Text("识别中...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
        }
    }

    @ViewBuilder
    private var textContentView: some View {
        let fullText = viewModel.stableText + viewModel.unfixedText
        let textHeight = calculateTextHeight(fullText)
        let displayHeight = min(textHeight, CGFloat(maxLines) * lineHeight)
        let needsScroll = textHeight > displayHeight
        let textWidth = maxWidth - 32

        if needsScroll {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    styledText
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: textWidth - 16, alignment: .leading)
                        .id("bottom")
                }
                .frame(width: textWidth, height: displayHeight)
                .onChange(of: viewModel.stableText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.unfixedText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        } else {
            styledText
                .font(.system(size: 13))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
        }
    }

    private var styledText: Text {
        let stable = Text(viewModel.stableText)
            .foregroundColor(.white.opacity(0.9))
        if viewModel.unfixedText.isEmpty {
            return stable
        }
        let unfixed = Text(viewModel.unfixedText)
            .foregroundColor(.white.opacity(0.45))
        return stable + unfixed
    }

    private func calculateTextHeight(_ text: String) -> CGFloat {
        let avgCharsPerLine = 25
        let lines = max(1, (text.count + avgCharsPerLine - 1) / avgCharsPerLine)
        return CGFloat(lines) * lineHeight
    }

    private func waveHeight(for index: Int) -> CGFloat {
        let phase = viewModel.animationPhase + CGFloat(index) * 0.6
        let baseHeight: CGFloat = 4
        let level = viewModel.audioLevel
        let dynamicAmplitude: CGFloat = 12 * level
        let jitter = abs(sin(phase)) * (2 + 4 * level)
        return baseHeight + dynamicAmplitude + jitter
    }
}
