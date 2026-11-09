import Foundation

/// 字节数格式化与可读化工具（架构 §2.2 `M/Support/Bytes.swift`）。
public enum Bytes {
    /// 二进制单位（1 KB = 1024 B）。
    public static let kibibyte: Int64 = 1024
    /// MiB。
    public static let mebibyte: Int64 = 1024 * 1024
    /// GiB。
    public static let gibibyte: Int64 = 1024 * 1024 * 1024
    /// TiB。
    public static let tebibyte: Int64 = 1024 * 1024 * 1024 * 1024

    /// 中文可读化格式（1024 进制）：`1.5 GB`。
    ///
    /// - Parameters:
    ///   - bytes: 字节数，允许为负（负值原样带负号输出）。
    ///   - fractionDigits: 小数位数，默认 1。
    public static func humanReadable(_ bytes: Int64, fractionDigits: Int = 1) -> String {
        let sign = bytes < 0 ? "-" : ""
        let magnitude = abs(bytes)
        var value = Double(magnitude)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var index = 0
        while value >= 1024.0 && index < units.count - 1 {
            value /= 1024.0
            index += 1
        }
        if index == 0 {
            return "\(sign)\(magnitude) B"
        }
        let format = String(format: "%.\(fractionDigits)f", value)
        return "\(sign)\(format) \(units[index])"
    }

    /// 紧凑格式（无空格），用于日志。
    public static func compact(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        let magnitude = abs(bytes)
        var value = Double(magnitude)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var index = 0
        while value >= 1024.0 && index < units.count - 1 {
            value /= 1024.0
            index += 1
        }
        return "\(sign)\(Int(value))\(units[index])"
    }

    /// 字节数组转十六进制字符串（小写，无分隔符）。
    public static func hexString(_ bytes: [UInt8]) -> String {
        hexString(bytes, separator: "")
    }

    /// 字节数组转十六进制字符串，可指定分隔符。
    public static func hexString(_ bytes: [UInt8], separator: String) -> String {
        guard !bytes.isEmpty else { return "" }
        var parts = [String]()
        parts.reserveCapacity(bytes.count)
        for byte in bytes {
            parts.append(String(byte, radix: 16, uppercase: false).leftPadded(to: 2, with: "0"))
        }
        return parts.joined(separator: separator)
    }

    /// 十六进制字符串解析为字节数组。非法字符返回 nil。
    public static func bytes(fromHex hex: String) -> [UInt8]? {
        let cleaned = hex.filter { $0 != " " && $0 != ":" && $0 != "\n" && $0 != "\r" && $0 != "\t" }
        guard cleaned.count % 2 == 0 else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

extension String {
    /// 左侧补齐到指定宽度。
    func leftPadded(to width: Int, with pad: String) -> String {
        guard count < width else { return self }
        return String(repeating: pad, count: width - count) + self
    }
}
