/// Apple 虚拟键码（与 Carbon kVK_* 一致），避免依赖 Carbon 框架
enum Key {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let `return`: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let space: Int64 = 49
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
    static let h: Int64 = 4
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
