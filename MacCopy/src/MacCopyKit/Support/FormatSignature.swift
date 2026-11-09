import Foundation

/// 提取格式串的占位符序列（含类型字符），用于与中文基准比对。
///
/// 存在意义（架构 V-A6，**致命项**）：`String(format: "共 %@ 项", 5)` 会把整数
/// 当作对象指针解引用，导致 **SIGSEGV / exit 139**，不是显示乱码。
/// 因此运行期必须校验译文的占位符签名与中文基准一致、且参数数量足够，
/// 任一不符就退回中文基准再格式化。
///
/// 覆盖 `%@` / `%d` / `%lld` / `%1$@` / `%zu` / `%%` 及常见长度/宽度修饰。
/// 本类型保持 internal（不暴露成 public API）。
enum FormatSignature {
    /// 占位符正则：与 `sync_catalog.py --check-languages` 使用同一套模式，
    /// 保证构建期与运行期判定一致（架构 §8 / T-I04 易错提示）。
    private static let pattern = "%(?:\\d+\\$)?[-+ #0]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@%dDuUxXoOfFeEgGcCsSaAp]"
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// 提取格式串中出现的所有占位符（按出现顺序）。
    ///
    /// - Parameter format: 待分析的字符串。
    /// - Returns: 占位符 token 数组，如 `["%@", "%d"]`。
    static func of(_ format: String) -> [String] {
        let range = NSRange(format.startIndex..., in: format)
        return regex.matches(in: format, range: range).compactMap { match in
            Range(match.range, in: format).map { String(format[$0]) }
        }
    }

    /// 占位符的「类型签名」（忽略位置参数前缀与宽度修饰，只保留类型字符）。
    /// 用于跨语言比对时允许 `%1$@` 与 `%@` 视为同类。
    ///
    /// - Parameter format: 待分析的字符串。
    /// - Returns: 类型字符数组，如 `["@", "d"]`。
    static func types(of format: String) -> [Character] {
        of(format).compactMap { token in
            // 最后一个字符就是类型字符（@ / d / f / … / %）。
            token.last
        }
    }
}
