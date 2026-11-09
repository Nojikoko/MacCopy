import Foundation

/// checksum 清单生成（P1-07）。
///
/// 输出格式：`<64位hex>  <相对路径>\n`（**两个空格**分隔），兼容 `shasum -c`。
public struct ChecksumFileWriter: Sendable {
    /// 生成 sha256 / md5 格式清单。
    ///
    /// - Parameters:
    ///   - entries: 条目列表（相对路径 + 摘要）。
    ///   - algorithm: 算法标识（决定文件扩展名）。
    ///   - to: 输出文件 URL。
    public static func write(
        entries: [(relativePath: String, digest: String)],
        algorithm: ChecksumAlgorithmID,
        to url: URL
    ) throws {
        var lines = [String]()
        lines.reserveCapacity(entries.count)
        for entry in entries {
            // `shasum` 惯例：反斜杠需转义；中文路径以 UTF-8 原样写入。
            let escaped = escapePath(entry.relativePath)
            lines.append("\(entry.digest)  \(escaped)")
        }
        let content = lines.joined(separator: "\n")
        var data = Data(content.utf8)
        // 末尾补换行，符合 `shasum -c` 期望。
        if !content.isEmpty { data.append(0x0A) }
        try data.write(to: url)
    }

    /// 生成清单文件内容（不落盘），便于测试与复用。
    ///
    /// - Parameters:
    ///   - entries: 条目列表。
    /// - Returns: 清单文本内容。
    public static func content(for entries: [(relativePath: String, digest: String)]) -> String {
        let lines = entries.map { "\($0.digest)  \(escapePath($0.relativePath))" }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 推荐的文件扩展名。
    ///
    /// - Parameter algorithm: 算法标识。
    /// - Returns: 扩展名（不含点）。
    public static func fileExtension(for algorithm: ChecksumAlgorithmID) -> String {
        switch algorithm {
        case .sha256: return "sha256"
        case .md5: return "md5"
        case .sha1: return "sha1"
        case .crc32: return "crc32"
        case .blake3: return "blake3"
        }
    }

    /// 转义路径中的特殊字符（`shasum` 惯例）。
    private static func escapePath(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count)
        for character in path {
            if character == "\\" {
                result += "\\\\"
            } else if character == "\n" {
                result += "\\n"
            } else {
                result.append(character)
            }
        }
        return result
    }
}
