import Foundation

/// 算法标识。新增算法只加枚举 case + 注册实现，不改引擎（P2-01 扩展点）。
///
/// 本文件在 T02 阶段建立「空壳」枚举（只声明 case，不含实现），
/// 目的是让 T02 的 `MacCopyError.checksumMismatch` 可以立即引用本类型；
/// 具体算法实现由 T03 在 `ChecksumAlgorithm.swift` 等文件中补齐。
///
/// `CodingKeyRepresentable` 约定：
/// 本枚举被用作**字典键**持久化（`ResumeRecord.partialDigests`），
/// 而 `JSONEncoder` 对非 String/Int 键的字典会编码成**数组**，
/// 导致回读时 `decode` 失败、记录被静默丢弃。
/// 遵循 `CodingKeyRepresentable` 后可正常按字符串键编解码。
public enum ChecksumAlgorithmID: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    /// CRC32（IEEE 802.3 多项式）。
    case crc32
    /// MD5。
    case md5
    /// SHA-1。
    case sha1
    /// SHA-256。
    case sha256
    /// BLAKE3。
    case blake3

    /// P2-01 预留：sha224, sha384, sha512, sha3, whirlpool, xxhash3, crc16 ...

    /// 中文展示名（用于 UI 与报告）。
    public var displayName: String {
        switch self {
        case .crc32: return "CRC32"
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .blake3: return "BLAKE3"
        }
    }

    /// 摘要字节长度。
    public var digestLength: Int {
        switch self {
        case .crc32: return 4
        case .md5: return 16
        case .sha1: return 20
        case .sha256: return 32
        case .blake3: return 32
        }
    }
}
