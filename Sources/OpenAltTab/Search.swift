import Foundation

/// 搜索匹配：分层评分（对齐上游 tierMatch 思路，免费实现）。
/// 应用名分数 ×1.02 略高于标题——同时命中时按应用名排前，与上游一致。
enum Search {
    /// 归一化：小写 + 去变音符 + 全半角折叠（CJK 文本不受影响）
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: Locale.current)
    }

    /// 0…1 相关性：前缀 > 词边界 > 任意子串 > 子序列模糊匹配
    static func score(query: String, text: String) -> Double {
        let q = normalize(query)
        let t = normalize(text)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 1 }
        if let r = t.range(of: q) {
            // 词边界：查询正好从分隔符后开始（如 "Saf" 命中 "my Safari"）
            let before = t[t.startIndex..<r.lowerBound]
            if before.last.map({ !$0.isLetter && !$0.isNumber }) ?? true { return 0.9 }
            return 0.7
        }
        return subsequenceMatch(query: q, text: t) ? 0.4 : 0
    }

    /// q 的字符按顺序全部出现在 t 中（不要求连续）
    private static func subsequenceMatch(query: String, text: String) -> Bool {
        var idx = text.startIndex
        for ch in query {
            guard let p = text[idx...].firstIndex(of: ch) else { return false }
            idx = text.index(after: p)
        }
        return true
    }

    static func bestSimilarity(query: String, appName: String, title: String) -> Double {
        max(score(query: query, text: appName) * 1.02, score(query: query, text: title))
    }
}
