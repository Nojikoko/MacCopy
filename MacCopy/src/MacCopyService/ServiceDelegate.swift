import AppKit
import Foundation
import MacCopyKit

/// Finder Service 入口（架构 T01 骨架）。
///
/// 当前只打印收到的路径；真实投递（NSXPCConnection / App Group）留给 T05。
/// 注意：本文件属于 Service target，允许 import AppKit（AD-02 只约束 `MacCopyKit`）。
final class ServiceDelegate: NSObject, NSServiceProvider {
    /// 接收 Finder 传入的文件列表。
    ///
    /// - Parameter pasteboard: 系统剪贴板。
    /// - Returns: 是否成功处理。
    func pasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return false
        }

        Log.ui.info("服务收到 \(urls.count, privacy: .public) 个项目")
        for url in urls {
            Log.ui.info("项目路径：\(url.path, privacy: .private)")
        }
        return true
    }
}
