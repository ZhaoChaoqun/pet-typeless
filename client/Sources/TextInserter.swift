import Foundation
import AppKit
import Carbon.HIToolbox

/// 文字插入工具 - 将文字插入到当前光标位置
struct TextInserter {

    /// 将文字插入到当前活动应用的光标位置
    static func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboardContents(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulatePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let expectedCount = changeCountBefore + 2
            if pasteboard.changeCount == expectedCount {
                restorePasteboardContents(pasteboard, items: savedItems)
            }
        }
    }

    /// 插入文字（不保存/恢复剪贴板，用于流式输入）
    static func insertTextDirect(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulatePaste()
    }

    // MARK: - Pasteboard Save/Restore

    private static func savePasteboardContents(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private static func restorePasteboardContents(_ pasteboard: NSPasteboard, items: [[(NSPasteboard.PasteboardType, Data)]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let pasteboardItems = items.map { typesAndData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typesAndData {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    // MARK: - Key Simulation

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            return
        }
        keyDown.flags = .maskCommand

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
