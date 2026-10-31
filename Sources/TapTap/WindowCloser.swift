import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum WindowCloser {
    static func closeWithShortcut(of processID: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "需要辅助功能权限" }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == processID,
              processID != ProcessInfo.processInfo.processIdentifier else {
            return "前台应用已切换，已取消关闭"
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: false) else {
            return "无法创建关闭快捷键"
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return "已向 \(app.localizedName ?? "当前应用") 发送 ⌘W"
    }

    static func closeFrontWindow(of processID: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "需要辅助功能权限" }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == processID,
              processID != ProcessInfo.processInfo.processIdentifier else {
            return "前台应用已切换，已取消关闭"
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let window = element(application, attribute: kAXFocusedWindowAttribute)
                ?? element(application, attribute: kAXMainWindowAttribute) else {
            return "当前没有可关闭的窗口"
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            for child in children {
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                   role as? String == kAXSheetRole {
                    return "窗口有对话框，请先处理对话框"
                }
            }
        }
        guard let button = element(window, attribute: kAXCloseButtonAttribute) else {
            return "当前窗口没有关闭按钮"
        }
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? Bool, !enabled {
            return "当前窗口的关闭按钮不可用"
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        return result == .success ? "已请求关闭 \(app.localizedName ?? "当前应用") 的窗口" : "关闭失败（\(result.rawValue)）"
    }

    private static func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
