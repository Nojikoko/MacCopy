import Foundation

/// 路径工具（架构 §2.2 `M/Support/PathUtil.swift`）。
///
/// 关注点：路径拼接、相对化、组件拆分、中文路径处理。
public enum PathUtil {
    /// macOS 的 PATH_MAX。
    public static let pathMax = 1024

    /// 路径的字节长度（macOS 以字节而非字符计量路径）。
    public static func byteLength(_ path: String) -> Int {
        path.utf8.count
    }

    /// 路径是否超出 macOS 的 PATH_MAX 限制。
    public static func isTooLong(_ path: String) -> Bool {
        byteLength(path) >= pathMax
    }

    /// 把路径拆成各级组件（去掉根目录分隔符）。
    ///
    /// - Parameter path: 待拆分路径。
    /// - Returns: 各级组件数组。
    public static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// 拼接路径（自动处理分隔符，避免出现双斜杠）。
    ///
    /// - Parameters:
    ///   - base: 基础路径。
    ///   - component: 待追加的组件。
    /// - Returns: 拼接后的路径。
    public static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.isEmpty { return base }
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }

    /// 相对化：把 `path` 相对于 `base` 转成相对路径。
    ///
    /// - Parameters:
    ///   - path: 目标路径。
    ///   - base: 基础路径。
    /// - Returns: 相对路径；若 `path` 不在 `base` 之下，返回 `path` 本身。
    public static func relative(_ path: String, to base: String) -> String {
        let normalizedPath = standardize(path)
        let normalizedBase = standardize(base)
        guard normalizedPath.hasPrefix(normalizedBase) else { return path }
        var remainder = String(normalizedPath.dropFirst(normalizedBase.count))
        if remainder.hasPrefix("/") { remainder.removeFirst() }
        return remainder.isEmpty ? "." : remainder
    }

    /// 标准化路径（展开 `~`、消除重复分隔符、解析 `.` 与 `..`）。
    ///
    /// - Parameter path: 原始路径。
    /// - Returns: 标准化后的路径。
    public static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let isAbsolute = expanded.hasPrefix("/")
        var stack = [String]()
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
                continue
            }
            stack.append(String(part))
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// 判断路径是否在 `base` 目录之下（含 `base` 自身）。
    public static func isDescendant(_ path: String, of base: String) -> Bool {
        let normalizedPath = standardize(path)
        let normalizedBase = standardize(base)
        if normalizedPath == normalizedBase { return true }
        return normalizedPath.hasPrefix(normalizedBase.hasSuffix("/") ? normalizedBase : normalizedBase + "/")
    }

    /// 判断是否为隐藏文件（末段以 `.` 开头）。
    public static func isHidden(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(".")
    }

    /// 追加「副本」序号，用于自动重命名解决冲突。
    ///
    /// - Parameters:
    ///   - name: 原文件名。
    ///   - index: 副本序号（从 1 开始）。
    /// - Returns: 新文件名。
    public static func renamed(_ name: String, index: Int) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let suffix = Localization.format(
            "filename.copySuffix",
            default: "副本 %d",
            index
        )
        if ext.isEmpty {
            return "\(base) \(suffix)"
        }
        return "\(base) \(suffix).\(ext)"
    }

    /// 中文路径是否安全（UTF-8 编码完整，无空字节）。
    public static func isValidUTF8Path(_ path: String) -> Bool {
        !path.contains("\0") && !path.utf8.contains(0)
    }
}
