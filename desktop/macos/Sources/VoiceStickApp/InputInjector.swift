import AppKit
import ApplicationServices
import Foundation

final class InputInjector {
    private var pendingPasteboardRestore: DispatchWorkItem?
    private let pasteboardRestoreDelay: TimeInterval = 1.2
    private let retryPasteDelay: TimeInterval = 0.18

    func paste(text: String, pressEnter: Bool) -> Bool {
        guard !text.isEmpty else { return true }
        guard isAccessibilityTrusted(promptIfNeeded: true) else {
            AppLog.error("InputInjector accessibility not trusted")
            return false
        }

        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map(PasteboardItemSnapshot.init)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let focusedTextBeforePaste = currentFocusedTextSnapshot()
        pendingPasteboardRestore?.cancel()

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        let temporaryChangeCount = pasteboard.changeCount
        AppLog.debug("InputInjector pasteboard Command+V text_len=\(text.count)")
        sendCommandV()

        if shouldRetryPaste(for: frontmostApp?.bundleIdentifier) {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryPasteDelay) {
                let focusedTextAfterPaste = self.currentFocusedTextSnapshot()
                guard self.shouldRetryPaste(
                    before: focusedTextBeforePaste,
                    after: focusedTextAfterPaste
                ) else { return }
                AppLog.debug("InputInjector retrying Command+V")
                self.sendCommandV()
            }
        }

        if pressEnter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.releaseCommandKey()
                self.sendReturn()
            }
        }

        let restoreWorkItem = DispatchWorkItem {
            guard pasteboard.changeCount == temporaryChangeCount else { return }

            pasteboard.prepareForNewContents(with: .currentHostOnly)
            let restoredItems = previousItems?.map(\.pasteboardItem) ?? []
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            } else {
                pasteboard.clearContents()
            }
            AppLog.debug("InputInjector pasteboard restored")
        }
        pendingPasteboardRestore = restoreWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay, execute: restoreWorkItem)

        return true
    }

    private func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func sendCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        commandDown?.flags = .maskCommand
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        commandUp?.flags = []
        commandDown?.post(tap: .cghidEventTap)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }

    private func releaseCommandKey() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        commandUp?.flags = []
        commandUp?.post(tap: .cghidEventTap)
    }

    private func sendReturn() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        keyDown?.flags = []
        keyUp?.flags = []
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func shouldRetryPaste(for bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.openai.codex" || bundleIdentifier == "com.openai.chatgpt"
    }

    private func shouldRetryPaste(before: FocusedTextSnapshot?, after: FocusedTextSnapshot?) -> Bool {
        guard
            let before,
            let after,
            before.pid == after.pid,
            let beforeValue = before.value,
            let afterValue = after.value
        else {
            return false
        }

        return beforeValue == afterValue
    }

    private func currentFocusedTextSnapshot() -> FocusedTextSnapshot? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard result == .success, let focusedElement = focusedElementValue else { return nil }

        let axElement = unsafeBitCast(focusedElement, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(axElement, &pid) == .success else { return nil }

        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef)
        let value = valueResult == .success ? valueRef as? String : nil
        return FocusedTextSnapshot(pid: pid, value: value)
    }
}

private struct FocusedTextSnapshot {
    let pid: pid_t
    let value: String?
}

private struct PasteboardItemSnapshot {
    private let contents: [(type: NSPasteboard.PasteboardType, data: Data)]

    init(item: NSPasteboardItem) {
        contents = item.types.compactMap { type in
            guard let data = item.data(forType: type) else { return nil }
            return (type, data)
        }
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for content in contents {
            item.setData(content.data, forType: content.type)
        }
        return item
    }
}
