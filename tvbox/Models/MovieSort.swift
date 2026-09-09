import Foundation

/// 分类排序模型 - 对应 Android 版 MovieSort.java
struct MovieSort: Codable {
    /// 分类列表（包含首页推荐、影视分类等）。
    var sortList: [SortData] = []
    
    /// 单个分类数据
    struct SortData: Codable, Identifiable, Hashable {
        /// 分类唯一标识（接口字段通常为 type_id）。
        var id: String
        /// 分类显示名。
        var name: String = ""
        /// 标记位（不同源可定义不同语义，常用于首页/推荐标识）。
        var flag: String = ""
        /// 分类下可选筛选项（年份、地区、类型等）。
        var filters: [SortFilter] = []
        
        init(id: String = "", name: String = "", flag: String = "") {
            self.id = id
            self.name = name
            self.flag = flag
        }
        
        /// 验证分类名称是否为有效语义名称（丢弃无法解析的占位符与脏数据）
        static func cleanCategoryName(_ rawName: String) -> String? {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            
            let lower = trimmed.lowercased()
            // 常见未解析关键字与代码占位符
            let invalidKeywords = [
                "undefined", "null", "none", "nan", "[object object]",
                "{}", "[]", "fyclass", "fypage", "__xptv_tab",
                "false", "true", "nil"
            ]
            if invalidKeywords.contains(lower) {
                return nil
            }
            
            // 丢弃未解析的 JSON 格式或参数串
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.contains("\"ext\":") {
                return nil
            }
            
            // 纯符号无有效字符
            let alphanumericOrChinese = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FA5}"))
            if trimmed.unicodeScalars.allSatisfy({ !alphanumericOrChinese.contains($0) }) {
                return nil
            }
            
            return trimmed
        }
        
        /// 生成首页推荐占位分类。
        /// 该分类不走常规分类接口，直接渲染首页推荐列表。
        static func home() -> SortData {
            SortData(id: "home", name: "推荐", flag: "1")
        }
    }
    
    /// 筛选条件
    struct SortFilter: Codable, Hashable {
        /// 接口参数键，例如 `year`、`area`。
        var key: String = ""
        /// UI 展示名称。
        var name: String = ""
        /// 可选值集合。
        var values: [SortFilterValue] = []
        
        struct SortFilterValue: Codable, Hashable {
            /// 展示名。
            var n: String = ""
            /// 真实参数值。
            var v: String = ""
        }
    }
}
