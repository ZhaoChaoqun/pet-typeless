import SwiftUI

/// 设置视图
struct SettingsView: View {
    var body: some View {
        Form {
            SettingsServerView()
            SettingsGeneralView()
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 450)
    }
}

/// Server 连接设置
struct SettingsServerView: View {
    @State private var serverURL: String = ServerConfig.serverURL.absoluteString
    @State private var apiToken: String = ServerConfig.apiToken
    @State private var isConnected: Bool = RecordingManager.shared.isInitialized

    var body: some View {
        Section {
            TextField("Server URL", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: serverURL) { _, newValue in
                    if let url = URL(string: newValue) {
                        ServerConfig.serverURL = url
                    }
                }

            SecureField("API Token", text: $apiToken)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiToken) { _, newValue in
                    ServerConfig.apiToken = newValue
                }

            HStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(isConnected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("重新连接") {
                    RecordingManager.shared.reconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } header: {
            Text("服务器")
        } footer: {
            Text("连接到 PetTypeless Relay Server。语音识别和文本优化都在服务器端完成。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverConnectionChanged)) { notification in
            if let connected = notification.object as? Bool {
                isConnected = connected
            }
        }
    }
}

/// 通用设置视图（快捷键、关于、权限）
struct SettingsGeneralView: View {
    @State private var triggerKeyName: String = TriggerKeyConfig.current.displayName
    @State private var isRecording = false

    var body: some View {
        Section {
            HStack {
                Text("触发键")
                Spacer()
                if isRecording {
                    Text("请按下任意键...")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(triggerKeyName)
                        .foregroundStyle(.secondary)
                }
                Button(isRecording ? "取消" : "录制按键") {
                    if isRecording {
                        isRecording = false
                        NotificationCenter.default.post(
                            name: .triggerKeyRecordingCancelled, object: nil)
                    } else {
                        isRecording = true
                        NotificationCenter.default.post(
                            name: .triggerKeyRecordingRequested, object: nil)
                    }
                }
                .buttonStyle(.bordered)
            }
            if triggerKeyName != TriggerKeyConfig.defaultFn.displayName {
                Button("恢复默认 (Fn)") {
                    TriggerKeyConfig.defaultFn.save()
                    triggerKeyName = TriggerKeyConfig.defaultFn.displayName
                    NotificationCenter.default.post(name: .triggerKeyChanged, object: nil)
                }
            }
        } header: {
            Text("快捷键")
        } footer: {
            Text("长按所选按键开始录音，松开结束。外接机械键盘的 Fn 键通常无法被系统检测，建议录制其他按键。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerKeyRecorded)) { notification in
            if let config = notification.object as? TriggerKeyConfig {
                triggerKeyName = config.displayName
                isRecording = false
            }
        }

        Section("关于") {
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
            LabeledContent("作者", value: "赵超群（Zhao Chaoqun）")
        }

        Section {
            Link("辅助功能设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            Link("麦克风设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } header: {
            Text("权限")
        } footer: {
            Text("PetTypeless 需要辅助功能权限来监听全局按键，需要麦克风权限来录制语音。")
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let serverConnectionChanged = Notification.Name("serverConnectionChanged")
}

#Preview {
    SettingsView()
}
