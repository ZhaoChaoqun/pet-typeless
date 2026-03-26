import SwiftUI
import AppKit

/// 首次启动引导状态
enum OnboardingState {
    case connecting         // 正在连接服务器
    case needsConfig        // 需要配置服务器信息
    case ready              // 准备就绪
}

/// 引导界面视图模型
class OnboardingViewModel: ObservableObject {
    @Published var state: OnboardingState = .connecting
    @Published var isVisible: Bool = false

    private var pollTimer: Timer?
    private var autoDismissTimer: Timer?

    deinit {
        cleanup()
    }

    private func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    func checkStatus() {
        if !ServerConfig.isConfigured {
            state = .needsConfig
        } else if RecordingManager.shared.isInitialized {
            state = .ready
            startAutoDismissTimer()
        } else {
            state = .connecting
            startPolling()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            if RecordingManager.shared.isInitialized {
                timer.invalidate()
                self.pollTimer = nil
                self.state = .ready
                self.startAutoDismissTimer()
            }
        }
    }

    private func startAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.isVisible = false
        }
    }
}

/// 引导气泡窗口控制器
class OnboardingWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OnboardingBubbleView>?
    private var viewModel = OnboardingViewModel()
    private var statusItemFrame: NSRect = .zero
    private var visibilityTimer: Timer?

    private let hasShownOnboardingKey = "hasShownOnboarding"

    private func setupWindow() {
        let contentView = OnboardingBubbleView(viewModel: viewModel) { [weak self] in
            self?.dismiss()
        }
        hostingView = NSHostingView(rootView: contentView)
        hostingView?.frame = NSRect(x: 0, y: 0, width: 280, height: 100)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 100),
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
        window.hasShadow = true
    }

    var shouldShowOnboarding: Bool {
        return !UserDefaults.standard.bool(forKey: hasShownOnboardingKey)
    }

    func setStatusItemFrame(_ frame: NSRect) {
        self.statusItemFrame = frame
    }

    func show() {
        guard shouldShowOnboarding else { return }

        setupWindow()
        viewModel.isVisible = true
        viewModel.checkStatus()
        startVisibilityObserver()
        positionWindow()
        window?.orderFront(nil)
    }

    private func startVisibilityObserver() {
        visibilityTimer?.invalidate()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if !self.viewModel.isVisible {
                timer.invalidate()
                self.dismiss()
            }
        }
    }

    private func positionWindow() {
        guard let window = window, let screen = NSScreen.main else { return }

        let windowSize = window.frame.size
        let screenFrame = screen.frame

        if statusItemFrame != .zero {
            let x = statusItemFrame.midX - windowSize.width / 2
            let y = screenFrame.maxY - statusItemFrame.height - windowSize.height - 8
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            let x = screenFrame.maxX - windowSize.width - 20
            let y = screenFrame.maxY - 30 - windowSize.height
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func dismiss() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        viewModel.isVisible = false
        window?.orderOut(nil)
        UserDefaults.standard.set(true, forKey: hasShownOnboardingKey)
    }
}

/// 引导气泡视图
struct OnboardingBubbleView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 16, height: 8)

            HStack(spacing: 12) {
                iconView
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    mainText
                    subtitleText
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var iconView: some View {
        switch viewModel.state {
        case .connecting:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
        case .needsConfig:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)
        }
    }

    @ViewBuilder
    private var mainText: some View {
        switch viewModel.state {
        case .connecting:
            Text("正在连接服务器")
                .font(.system(size: 13, weight: .medium))
        case .needsConfig:
            Text("请配置服务器")
                .font(.system(size: 13, weight: .medium))
        case .ready:
            Text("长按 Fn 键开始说话")
                .font(.system(size: 13, weight: .medium))
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        switch viewModel.state {
        case .connecting:
            Text("连接中，请稍候...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .needsConfig:
            Text("在设置中填写 Server URL 和 API Token")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .ready:
            Text("松开即可输入识别的文字")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

/// 小三角形状
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
