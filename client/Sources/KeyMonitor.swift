import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.pettypeless.app", category: "KeyMonitor")

/// 触发键配置，仅支持修饰键（Fn/Command/Option/Control/Shift）
struct TriggerKeyConfig: Codable, Equatable {
    /// 按键的 keyCode（Fn 为 -1，其他修饰键使用实际 keyCode 区分左右）
    let keyCode: Int64
    /// 修饰键的 flag 掩码（如 .maskSecondaryFn = 0x800000）
    let flagMask: UInt64
    /// 用户可读的按键名称
    let displayName: String

    /// 默认触发键：Fn
    static let defaultFn = TriggerKeyConfig(
        keyCode: -1,
        flagMask: CGEventFlags.maskSecondaryFn.rawValue,
        displayName: "Fn"
    )

    /// 从 UserDefaults 读取，默认 Fn。若旧配置为非修饰键则回退到默认值。
    static var current: TriggerKeyConfig {
        guard let data = UserDefaults.standard.data(forKey: "triggerKeyConfig"),
              let config = try? JSONDecoder().decode(TriggerKeyConfig.self, from: data) else {
            return .defaultFn
        }
        // 迁移：旧版本可能存了非修饰键配置（flagMask == 0），回退到默认 Fn
        if config.flagMask == 0 {
            defaultFn.save()
            return .defaultFn
        }
        return config
    }

    /// 保存到 UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "triggerKeyConfig")
        }
    }

    /// 检查 flagsChanged 事件是否匹配此触发键，返回是否按下
    func matches(type: CGEventType, event: CGEvent) -> Bool? {
        guard type == .flagsChanged else { return nil }
        if keyCode >= 0 {
            let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard eventKeyCode == keyCode else { return nil }
        }
        return event.flags.rawValue & flagMask != 0
    }
}

// MARK: - Notification for trigger key changes

extension Notification.Name {
    static let triggerKeyChanged = Notification.Name("triggerKeyChanged")
    static let triggerKeyRecordingRequested = Notification.Name("triggerKeyRecordingRequested")
    static let triggerKeyRecordingCancelled = Notification.Name("triggerKeyRecordingCancelled")
    static let triggerKeyRecorded = Notification.Name("triggerKeyRecorded")
}

/// 监听全局修饰键按下/松开（Fn/Command/Option/Control/Shift）
class KeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onKeyRecorded: ((TriggerKeyConfig) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTriggerPressed = false
    private var permissionCheckTimer: Timer?
    private var triggerConfig: TriggerKeyConfig = .current

    private let _isRecordingKey = OSAllocatedUnfairLock(initialState: false)
    var isRecordingKey: Bool {
        get { _isRecordingKey.withLock { $0 } }
        set { _isRecordingKey.withLock { $0 = newValue } }
    }

    func startMonitoring() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            logger.info("检测到单元测试环境，跳过键盘监听")
            return
        }

        let trusted = AXIsProcessTrusted()
        logger.info("辅助功能权限状态: \(trusted ? "已授权" : "未授权", privacy: .public)")

        guard trusted else {
            logger.info("需要辅助功能权限")
            requestAccessibilityPermission()
            startPermissionPolling()
            return
        }

        stopPermissionPolling()

        guard eventTap == nil else {
            logger.debug("事件监听器已存在")
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)

        triggerConfig = .current
        logger.info("触发键: \(self.triggerConfig.displayName, privacy: .public)")

        // Use .listenOnly — we only observe the trigger key, never block/modify
        // events. An active (.defaultTap) filter serialises every keystroke
        // through our callback, which stalls typing system-wide whenever the
        // main thread has any latency.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.info("无法创建事件监听 - 请检查辅助功能权限")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("触发键监听已启动（\(self.triggerConfig.displayName, privacy: .public)）")
    }

    func restartWithNewTriggerKey() {
        if isTriggerPressed {
            onKeyUp?()
        }
        stopMonitoring()
        isTriggerPressed = false
        triggerConfig = .current
        startMonitoring()
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.debug("事件监听被禁用，正在重新启用...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if isRecordingKey {
            if let config = captureKeyConfig(type: type, event: event) {
                isRecordingKey = false
                logger.info("录制到新触发键: \(config.displayName, privacy: .public) (keyCode=\(config.keyCode))")
                DispatchQueue.main.async {
                    self.onKeyRecorded?(config)
                }
            }
            return Unmanaged.passRetained(event)
        }

        if let pressed = triggerConfig.matches(type: type, event: event) {
            handleTriggerState(pressed: pressed)
        }

        return Unmanaged.passRetained(event)
    }

    /// 从 flagsChanged 事件中捕获修饰键配置（用于录制模式）
    private func captureKeyConfig(type: CGEventType, event: CGEvent) -> TriggerKeyConfig? {
        guard type == .flagsChanged else { return nil }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if flags.contains(.maskSecondaryFn) {
            return TriggerKeyConfig(keyCode: -1,
                                    flagMask: CGEventFlags.maskSecondaryFn.rawValue, displayName: "Fn")
        }
        if flags.contains(.maskCommand) {
            let name = keyCode == 54 ? "Right Command ⌘" : "Left Command ⌘"
            return TriggerKeyConfig(keyCode: keyCode,
                                    flagMask: CGEventFlags.maskCommand.rawValue, displayName: name)
        }
        if flags.contains(.maskAlternate) {
            let name = keyCode == 61 ? "Right Option ⌥" : "Left Option ⌥"
            return TriggerKeyConfig(keyCode: keyCode,
                                    flagMask: CGEventFlags.maskAlternate.rawValue, displayName: name)
        }
        if flags.contains(.maskControl) {
            let name = keyCode == 62 ? "Right Control ⌃" : "Left Control ⌃"
            return TriggerKeyConfig(keyCode: keyCode,
                                    flagMask: CGEventFlags.maskControl.rawValue, displayName: name)
        }
        if flags.contains(.maskShift) {
            let name = keyCode == 60 ? "Right Shift ⇧" : "Left Shift ⇧"
            return TriggerKeyConfig(keyCode: keyCode,
                                    flagMask: CGEventFlags.maskShift.rawValue, displayName: name)
        }
        return nil
    }

    private func handleTriggerState(pressed: Bool) {
        if pressed && !isTriggerPressed {
            isTriggerPressed = true
            logger.info("\(self.triggerConfig.displayName, privacy: .public) 按下，触发录音")
            DispatchQueue.main.async {
                self.onKeyDown?()
            }
        } else if !pressed && isTriggerPressed {
            isTriggerPressed = false
            logger.info("\(self.triggerConfig.displayName, privacy: .public) 松开，停止录音")
            DispatchQueue.main.async {
                self.onKeyUp?()
            }
        }
    }

    func stopMonitoring() {
        stopPermissionPolling()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        logger.info("开始轮询辅助功能权限状态...")
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                logger.info("辅助功能权限已授予，重新启动监听")
                timer.invalidate()
                self?.permissionCheckTimer = nil
                DispatchQueue.main.async {
                    self?.startMonitoring()
                }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    private func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    deinit {
        stopMonitoring()
    }
}
