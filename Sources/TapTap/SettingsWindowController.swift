import AppKit

final class SettingsWindowController: NSWindowController {
    private let settings: GestureSettings
    private var pickers: [GestureBinding: NSPopUpButton] = [:]
    private var statusTimer: Timer?

    init(settings: GestureSettings, statusProvider: @escaping () -> String) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TapTap 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "手势配置")
        title.font = .boldSystemFont(ofSize: 20)
        let subtitle = NSTextField(wrappingLabelWithString: "按手指数、轻触或按下、单击或双击分别设置动作。")
        subtitle.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [2, 3].flatMap { fingers in
            GestureBinding.allCases.filter { $0.fingers == fingers }.map { binding -> [NSView] in
                let label = NSTextField(labelWithString: binding.title)
                let picker = NSPopUpButton(frame: .zero, pullsDown: false)
                picker.addItems(withTitles: GestureAction.allCases.map(\.title))
                picker.selectItem(at: GestureAction.allCases.firstIndex(of: settings.action(for: binding))!)
                picker.tag = GestureBinding.allCases.firstIndex(of: binding)!
                picker.target = self
                picker.action = #selector(changeAction(_:))
                picker.setAccessibilityLabel(binding.title)
                pickers[binding] = picker
                return [label, picker]
            }
        })
        grid.columnSpacing = 50
        grid.rowSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.yPlacement = .center
        let note = NSTextField(wrappingLabelWithString: "轻触：接触后抬指，无需按压；按下：按出触控板点击反馈。\n同一组合同时启用单击和双击时，单击等待双击判定；按下不会触发轻触动作。\n系统右键、查找仍可能同时触发，可在系统触控板设置中调整。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let restore = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefaults))
        let saved = NSTextField(labelWithString: "更改自动保存并立即生效")
        saved.font = .systemFont(ofSize: 11)
        saved.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [restore, saved])
        footer.spacing = 16
        let status = NSTextField(wrappingLabelWithString: statusProvider())
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak status] _ in
            guard self?.window?.isVisible == true else { return }
            status?.stringValue = statusProvider()
        }
        statusTimer?.tolerance = 0.2
        let stack = NSStackView(views: [title, subtitle, grid, note, footer, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { statusTimer?.invalidate() }

    @objc private func changeAction(_ sender: NSPopUpButton) {
        settings.setAction(GestureAction.allCases[sender.indexOfSelectedItem],
                           for: GestureBinding.allCases[sender.tag])
    }

    @objc private func restoreDefaults() {
        settings.restoreDefaults()
        for (binding, picker) in pickers {
            picker.selectItem(at: GestureAction.allCases.firstIndex(of: settings.action(for: binding))!)
        }
    }
}
