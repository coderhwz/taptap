import Foundation
import GestureCore

enum GestureAction: String, CaseIterable {
    case none, closeWindow, closeTab

    var title: String {
        switch self {
        case .none: return "不执行"
        case .closeWindow: return "关闭当前窗口"
        case .closeTab: return "关闭标签页或窗口（⌘W）"
        }
    }
}

enum GestureBinding: String, CaseIterable {
    case twoSingle, twoDouble, threeSingle, threeDouble
    case twoPressSingle, twoPressDouble, threePressSingle, threePressDouble

    var fingers: Int {
        switch self {
        case .twoSingle, .twoDouble, .twoPressSingle, .twoPressDouble: return 2
        default: return 3
        }
    }
    var kind: TapKind {
        switch self {
        case .twoSingle, .threeSingle, .twoPressSingle, .threePressSingle: return .single
        default: return .double
        }
    }
    var isPress: Bool { [.twoPressSingle, .twoPressDouble, .threePressSingle, .threePressDouble].contains(self) }
    var title: String {
        "\(fingers == 2 ? "两指" : "三指") · \(isPress ? "按下" : "轻触") · \(kind == .single ? "单击" : "双击")"
    }
    var defaultAction: GestureAction { self == .threeDouble ? .closeWindow : .none }

    static func binding(fingers: Int, kind: TapKind, isPress: Bool = false) -> GestureBinding {
        if isPress {
            if fingers == 2 { return kind == .single ? .twoPressSingle : .twoPressDouble }
            return kind == .single ? .threePressSingle : .threePressDouble
        }
        if fingers == 2 { return kind == .single ? .twoSingle : .twoDouble }
        return kind == .single ? .threeSingle : .threeDouble
    }
}

final class GestureSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func action(for binding: GestureBinding) -> GestureAction {
        guard let value = defaults.string(forKey: "gesture.\(binding.rawValue)"),
              let action = GestureAction(rawValue: value) else { return binding.defaultAction }
        return action
    }

    func setAction(_ action: GestureAction, for binding: GestureBinding) {
        defaults.set(action.rawValue, forKey: "gesture.\(binding.rawValue)")
        onChange?()
    }

    func restoreDefaults() {
        for binding in GestureBinding.allCases { defaults.removeObject(forKey: "gesture.\(binding.rawValue)") }
        onChange?()
    }
}
