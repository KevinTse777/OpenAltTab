import CoreGraphics

/// Apple 虚拟键码（与 Carbon kVK_* 一致），避免依赖 Carbon 框架
enum Key {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let `return`: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let space: Int64 = 49
    static let backspace: Int64 = 51
    static let slash: Int64 = 44
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
    static let h: Int64 = 4
    static let f: Int64 = 3
    static let m: Int64 = 46
    static let q: Int64 = 12
    static let w: Int64 = 13
    static let one: Int64 = 18
    static let two: Int64 = 19
    static let three: Int64 = 20
    static let four: Int64 = 21
    static let five: Int64 = 23
    static let six: Int64 = 22
    static let seven: Int64 = 26
    static let eight: Int64 = 28
    static let nine: Int64 = 25
    static let zero: Int64 = 29

    /// 1–9、0 依次对应窗口下标 0–9
    static let digits: [Int64] = [one, two, three, four, five, six, seven, eight, nine, zero]
}

/// 通用触发键定义："⌃⌥Tab" 之类的规格串 → 修饰键 + 键码。
/// ⌘ 保留给系统切换器（规格含 ⌘ 视为无效）；⇧ 只用于反向循环，不参与匹配
struct TriggerSpec: Equatable {
    let option: Bool
    let control: Bool
    let key: Int64

    static func parse(_ raw: String) -> TriggerSpec? {
        var option = false
        var control = false
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            switch first {
            case "⌃": control = true
            case "⌥": option = true
            case "⌘": return nil
            default: break
            }
            rest.removeFirst()
        }
        guard option || control else { return nil }
        let key: Int64
        switch rest.lowercased() {
        case "tab": key = Key.tab
        case "space", "空格": key = Key.space
        case "`", "backquote": key = 50
        default: return nil
        }
        return TriggerSpec(option: option, control: control, key: key)
    }

    /// 按逗号/分号/空格拆分批量解析
    static func parseAll(_ raw: String) -> [TriggerSpec] {
        raw.split(whereSeparator: { ",，;； ".contains($0) })
            .compactMap { parse(String($0)) }
    }
}

/// 搜索输入：从按键事件取可打印字符。
/// 在事件副本上清掉 ⌘⌃⌥ 再取 Unicode——面板开着时 ⌥ 一直按着，
/// 直接取会把每个字母变成组合特殊字符（å œ Æ …）
enum SearchInput {
    static func character(from event: CGEvent) -> String? {
        let copied = event.copy()
        guard let copy = copied as CGEvent? else { return nil }
        copy.flags = copy.flags.subtracting([.maskAlternate, .maskCommand, .maskControl])
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        copy.keyboardGetUnicodeString(maxStringLength: 8,
                                      actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        // 退格/回车等控制键都已单独处理，这里只放行可打印字符
        guard let first = s.unicodeScalars.first,
              first.value >= 0x20, first.value != 0x7F else { return nil }
        return s
    }
}
