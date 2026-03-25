import SwiftUI
import AppKit
import AVFoundation
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "PetTypelessApp")

@main
struct PetTypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayWindow: OverlayWindowController?
    var onboardingWindow: OnboardingWindowController?
    var keyMonitor: KeyMonitor?
    var settingsWindow: NSWindow?
    private var triggerKeyMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()

        _ = RecordingManager.shared
        overlayWindow = OverlayWindowController()

        setupRecordingCallbacks()

        keyMonitor = KeyMonitor()
        keyMonitor?.onKeyDown = {
            RecordingManager.shared.handleEvent(.fnKeyDown)
        }
        keyMonitor?.onKeyUp = {
            RecordingManager.shared.handleEvent(.fnKeyUp)
        }
        keyMonitor?.onKeyRecorded = { config in
            config.save()
            NotificationCenter.default.post(name: .triggerKeyRecorded, object: config)
            NotificationCenter.default.post(name: .triggerKeyChanged, object: nil)
        }
        keyMonitor?.startMonitoring()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTriggerKeyChanged),
            name: .triggerKeyChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRecordingRequested),
            name: .triggerKeyRecordingRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRecordingCancelled),
            name: .triggerKeyRecordingCancelled, object: nil)

        checkPermissions()
        showOnboardingIfNeeded()

        logger.info("PetTypeless launched")
    }

    @objc private func handleTriggerKeyChanged() {
        keyMonitor?.restartWithNewTriggerKey()
        updateTriggerKeyMenuText()
    }

    @objc private func handleRecordingRequested() {
        keyMonitor?.isRecordingKey = true
    }

    @objc private func handleRecordingCancelled() {
        keyMonitor?.isRecordingKey = false
    }

    private func updateTriggerKeyMenuText() {
        let keyName = TriggerKeyConfig.current.displayName
        triggerKeyMenuItem?.title = "长按 \(keyName) 键开始录音"
    }

    private func showOnboardingIfNeeded() {
        onboardingWindow = OnboardingWindowController()
        if onboardingWindow?.shouldShowOnboarding == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let button = self?.statusItem?.button, let buttonWindow = button.window {
                    let frameInScreen = buttonWindow.convertToScreen(button.frame)
                    self?.onboardingWindow?.setStatusItemFrame(frameInScreen)
                }
                self?.onboardingWindow?.show()
            }
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "PetTypeless")
        }

        let keyName = TriggerKeyConfig.current.displayName
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "PetTypeless - 云端语音输入", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let keyItem = NSMenuItem(title: "长按 \(keyName) 键开始录音", action: nil, keyEquivalent: "")
        triggerKeyMenuItem = keyItem
        menu.addItem(keyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func checkPermissions() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async { self.showPermissionAlert(for: "麦克风") }
            }
        }
    }

    private func showPermissionAlert(for permission: String) {
        let alert = NSAlert()
        alert.messageText = "需要\(permission)权限"
        alert.informativeText = "请在系统设置中授予 PetTypeless \(permission)访问权限"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            if permission == "麦克风" {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }

    private func setupRecordingCallbacks() {
        RecordingManager.shared.onRecordingStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.overlayWindow?.show()
            }
        }

        RecordingManager.shared.onPartialResult = { [weak self] stableText, unfixedText in
            DispatchQueue.main.async {
                self?.overlayWindow?.updateRecognizedText(stableText, unfixedText: unfixedText)
            }
        }

        RecordingManager.shared.onAudioLevel = { [weak self] level in
            self?.overlayWindow?.updateAudioLevel(level)
        }

        RecordingManager.shared.onProcessingStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.overlayWindow?.showProcessing()
            }
        }

        RecordingManager.shared.onFinalResult = { [weak self] text in
            DispatchQueue.main.async {
                self?.overlayWindow?.hide()
                if let text = text, !text.isEmpty {
                    TextInserter.insertText(text)
                }
            }
        }

        RecordingManager.shared.onConnectionStateChanged = { connected in
            NotificationCenter.default.post(name: .serverConnectionChanged, object: connected)
        }
    }

    @objc func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "PetTypeless 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 450))
        window.center()

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
