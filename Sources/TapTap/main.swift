import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var statusSymbol: String?
    private let settings = GestureSettings()
    private lazy var monitor = GestureMonitor(settings: settings)
    private var settingsWindow: SettingsWindowController?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var enabled = !UserDefaults.standard.bool(forKey: "paused")
    private var lastAction = "尚未执行动作"
    private var monitorError: String?

    private var statusText: String {
        guard enabled else { return monitorError.map { "已暂停 · \($0)" } ?? "已暂停" }
        return AXIsProcessTrusted() ? monitorError ?? "正在监听" : "等待辅助功能授权"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch must not install another recognizer.
        let identifier = Bundle.main.bundleIdentifier ?? "local.hwz.TapTap"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "TapTap · 触控板手势"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        monitor.onGesture = { [weak self] binding in
            guard let self, let app = NSWorkspace.shared.frontmostApplication else { return }
            let pid = app.processIdentifier
            let generation = self.monitor.generation
            // Keep AX calls outside the event-tap callback to prevent callback timeouts.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.monitor.isRunning,
                      self.monitor.generation == generation else { return }
                switch self.settings.action(for: binding) {
                case .none: break
                case .closeWindow: self.lastAction = "\(binding.title)：\(WindowCloser.closeFrontWindow(of: pid))"
                case .closeTab: self.lastAction = "\(binding.title)：\(WindowCloser.closeWithShortcut(of: pid))"
                }
            }
        }
        settings.onChange = { [weak self] in self?.monitor.reset() }
        monitor.onFailure = { [weak self] message in
            self?.pauseAfterFailure(message)
            self?.refreshMonitoring()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.monitor.reset()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.monitor.stop()
                self?.refreshMonitoring()
            })
        }
        refreshMonitoring()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshMonitoring()
        }
        permissionTimer?.tolerance = 1
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    private func refreshMonitoring() {
        if enabled && AXIsProcessTrusted() {
            if !monitor.start() {
                pauseAfterFailure(monitor.inputError ?? "监听启动失败，请检查权限后手动重新启用")
            }
        } else if monitor.isRunning {
            monitor.stop()
        }
        let symbol = !enabled ? "hand.tap" : monitor.isRunning ? "hand.tap.fill" : "exclamationmark.triangle"
        guard symbol != statusSymbol else { return }
        statusSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TapTap")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func pauseAfterFailure(_ message: String) {
        monitorError = message
        enabled = false
        UserDefaults.standard.set(true, forKey: "paused")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMonitoring()
        menu.removeAllItems()
        add("TapTap · 触控板手势", to: menu)
        add(statusText, to: menu)
        menu.addItem(.separator())
        let toggle = add("启用手势", action: #selector(toggleEnabled), to: menu)
        toggle.state = enabled ? .on : .off
        let preferences = add("设置…", action: #selector(showSettings), to: menu)
        preferences.keyEquivalent = ","
        add("授权辅助功能…", action: #selector(requestPermission), to: menu)
        if !CGPreflightListenEventAccess() {
            add("授权输入监控…", action: #selector(requestInputPermission), to: menu)
        }
        let login = add("开机启动", action: #selector(toggleLogin), to: menu)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            add("批准开机启动…", action: #selector(openLoginSettings), to: menu)
        }
        menu.addItem(.separator())
        add(lastAction, to: menu)
        add("触摸事件 \(monitor.eventCount) · 当前 \(monitor.lastFingerCount) 指 · 已识别 \(monitor.gestureCount) 次", to: menu)
        add("使用说明…", action: #selector(showHelp), to: menu)
        menu.addItem(.separator())
        let quit = add("退出 TapTap", action: #selector(quit), to: menu)
        quit.keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func showSettings() {
        monitor.reset()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, statusProvider: { [weak self] in
                guard let self else { return "" }
                return "\(self.statusText) · 触控板 \(self.monitor.deviceCount) · 接触帧 \(self.monitor.eventCount)\n当前 \(self.monitor.lastFingerCount) 指 · 压力事件 \(self.monitor.pressureEventCount) · 按下 \(self.monitor.pressCount) 次 · 已识别 \(self.monitor.gestureCount) 次\n\(self.lastAction)"
            })
            settingsWindow?.window?.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow?.window {
            settingsWindow = nil
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        monitorError = nil
        UserDefaults.standard.set(!enabled, forKey: "paused")
        refreshMonitoring()
    }

    @objc private func requestPermission(_ sender: Any?) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func requestInputPermission() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { openLoginSettings() }
            }
        } catch {
            alert("无法更新开机启动", message: "请先将 TapTap.app 放到“应用程序”目录再试。\n\(error.localizedDescription)")
        }
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func showHelp() {
        alert("TapTap", message: "在菜单“设置…”中配置两指或三指、轻触或按下、单击或双击，共八种组合。默认三指轻触双击关闭窗口。\n\n关闭最前面的窗口，等同点击红色关闭按钮；未保存内容由原应用提示。\n\n拖移、滑动、长按及四指操作不会触发。两指轻点可能同时触发系统右键菜单。若系统“三指轻点查找”产生干扰，请在系统设置 → 触控板 → 光标与点按中更改查找手势。\n\n授权后菜单显示“正在监听”。若触摸事件一直为 0，请退出重启；仍无事件请反馈系统版本。")
    }

    private func alert(_ title: String, message: String) {
        monitor.reset()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        monitor.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
