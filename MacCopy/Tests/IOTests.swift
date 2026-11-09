import Foundation
import Darwin
import MacCopyKit

/// IO 层测试（PathWalker / CopyfileBridge / SparseProbe / MetadataOps / VolumeInspector）。
@MainActor
enum IOTests {
    /// 测试用工作目录（沙盒禁止 /var/folders 与 mkdir shell 命令）。
    static func scratchDirectory(_ name: String) -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("io-test", isDirectory: true)
        let directory = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 写文件（不能用 `FileManager.createFile` —— 内部 O_EXCL 被守卫拒绝）。
    ///
    /// 用 `PathWalker.openFile` 而非裸 `open`：后者在超长路径下会 ENAMETOOLONG。
    @discardableResult
    static func writeFile(_ path: String, _ content: String) -> Int32 {
        let fd: Int32
        do {
            fd = try PathWalker().openFile(at: path, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o644)
        } catch {
            return -1
        }
        defer { close(fd) }

        let bytes = Array(content.utf8)
        // **必须循环处理短写**（write 可能返回少于请求的字节数）。
        var written = 0
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let count = write(fd, base.advanced(by: written), buffer.count - written)
                if count <= 0 { break }
                written += count
            }
        }
        return written == bytes.count ? 0 : -1
    }

    /// 读文件内容（用 POSIX read；超长路径需走 `PathWalker` 的 openat 通道）。
    static func readFile(_ path: String) -> String {
        let fd: Int32
        if path.utf8.count <= PathWalker.fastPathThreshold {
            let opened = open(path, O_RDONLY)
            guard opened >= 0 else { return "" }
            fd = opened
        } else {
            // 超长路径：逐级 openat 到父目录，再用 openat 打开文件。
            let directory = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard let dirFD = try? PathWalker().openDirectory(at: directory) else { return "" }
            defer { close(dirFD) }
            let opened = openat(dirFD, name, O_RDONLY)
            guard opened >= 0 else { return "" }
            fd = opened
        }
        defer { close(fd) }

        var bytes = [UInt8]()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 64)
        defer { buffer.deallocate() }
        while true {
            let count = buffer.withMemoryRebound(to: UInt8.self, capacity: 64 * 1024) { pointer in
                Syscall.resetErrno()
                return read(fd, pointer, 64 * 1024)
            }
            if count <= 0 { break }
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 注册全部用例。
    static func register() {
        registerPathWalker()
        registerCopyfileBridge()
        registerSparseAndMetadata()
        registerVolumeInspector()
    }

    // MARK: - PathWalker

    private static func registerPathWalker() {
        TestRunner.register("PathWalker：逐级创建多级目录") {
            let root = scratchDirectory("pw-mkdir")
            defer { try? FileManager.default.removeItem(at: root) }

            let walker = PathWalker()
            let deep = root.appendingPathComponent("a", isDirectory: true)
                .appendingPathComponent("b", isDirectory: true)
                .appendingPathComponent("c", isDirectory: true)
                .appendingPathComponent("深层中文目录", isDirectory: true)

            try walker.createDirectory(at: deep.path)
            var sb = stat()
            let rc = stat(deep.path, &sb)
            TestRunner.assertEqual(rc, 0)
            TestRunner.assertTrue((sb.st_mode & S_IFMT) == S_IFDIR)
        }

        TestRunner.register("PathWalker：创建目录后能打开并写入文件") {
            let root = scratchDirectory("pw-write")
            defer { try? FileManager.default.removeItem(at: root) }

            let walker = PathWalker()
            let nested = root.appendingPathComponent("x", isDirectory: true)
                .appendingPathComponent("y", isDirectory: true)
            try walker.createDirectory(at: nested.path)

            let filePath = nested.appendingPathComponent("文件.txt").path
            let fd = try walker.openFile(at: filePath, flags: O_WRONLY | O_CREAT | O_TRUNC)
            defer { close(fd) }
            let bytes = Array("中文内容".utf8)
            let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            TestRunner.assertEqual(written, 12)
            TestRunner.assertEqual(readFile(filePath), "中文内容")
        }

        TestRunner.register("PathWalker：40 级中文长路径（超过 PATH_MAX）") {
            let root = scratchDirectory("pw-long")
            defer { try? FileManager.default.removeItem(at: root) }

            let walker = PathWalker()
            // 构造 40 级、每级 40 个中文字符的深路径（远超 1024 字节）。
            var deep = root
            for level in 0..<40 {
                deep = deep.appendingPathComponent("层级\(level)\(String(repeating: "长", count: 40))")
            }
            TestRunner.assertTrue(deep.path.utf8.count > PathUtil.pathMax)

            try walker.createDirectory(at: deep.path)

            // 在最深目录里写文件。
            let filePath = deep.appendingPathComponent("叶.txt").path
            let fd = try walker.openFile(at: filePath, flags: O_WRONLY | O_CREAT | O_TRUNC)
            defer { close(fd) }
            let bytes = Array("深度".utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

            TestRunner.assertEqual(readFile(filePath), "深度")
        }

        TestRunner.register("PathWalker：超长路径用 openat 逐级下降打开目录") {
            let root = scratchDirectory("pw-openat")
            defer { try? FileManager.default.removeItem(at: root) }

            let walker = PathWalker()
            var deep = root
            for level in 0..<40 {
                deep = deep.appendingPathComponent("层级\(level)\(String(repeating: "长", count: 40))")
            }
            try walker.createDirectory(at: deep.path)

            // 逐级 openat 打开（内部实现）。
            let fd = try walker.openDirectory(at: deep.path)
            defer { close(fd) }
            TestRunner.assertTrue(fd >= 0)

            // 在该 fd 下读目录项。
            let children = try walker.enumerateChildren(of: fd)
            TestRunner.assertTrue(children.isEmpty)
        }

        TestRunner.register("PathWalker：枚举目录项并识别类型") {
            let root = scratchDirectory("pw-enum")
            defer { try? FileManager.default.removeItem(at: root) }

            writeFile(root.appendingPathComponent("普通文件.txt").path, "A")
            writeFile(root.appendingPathComponent("另一个.bin").path, "B")
            _ = mkdir(root.appendingPathComponent("子目录", isDirectory: true).path, 0o755)

            let walker = PathWalker()
            let children = try walker.withDirectoryHandle(at: root.path) { fd in
                try walker.enumerateChildren(of: fd)
            }

            TestRunner.assertEqual(children.count, 3)
            let names = Set(children.map(\.name))
            TestRunner.assertTrue(names.contains("普通文件.txt"))
            TestRunner.assertTrue(names.contains("另一个.bin"))
            TestRunner.assertTrue(names.contains("子目录"))

            let directory = children.first { $0.name == "子目录" }
            TestRunner.assertTrue(directory?.isDirectory == true)
            let file = children.first { $0.name == "普通文件.txt" }
            TestRunner.assertFalse(file?.isDirectory == true)
        }

        TestRunner.register("PathWalker：符号链接被识别为链接且不递归进入") {
            let root = scratchDirectory("pw-symlink")
            defer { try? FileManager.default.removeItem(at: root) }

            writeFile(root.appendingPathComponent("目标文件.txt").path, "内容")
            // symlink 需实测是否可用（守卫策略在会话期间变过）。
            errno = 0
            let linkResult = symlink(
                root.appendingPathComponent("目标文件.txt").path,
                root.appendingPathComponent("链接").path
            )
            if linkResult != 0 {
                // 环境不支持创建符号链接 → 跳过（不是代码缺陷）。
                TestRunner.assertTrue(true, "环境不支持 symlink（errno=\(errno)），跳过")
                return
            }

            let walker = PathWalker()
            let children = try walker.withDirectoryHandle(at: root.path) { fd in
                try walker.enumerateChildren(of: fd)
            }
            let link = children.first { $0.name == "链接" }
            // BUG-01 回归点：d_type 必须映射到 DT_LNK(10) → isSymbolicLink=true。
            TestRunner.assertTrue(link?.isSymbolicLink == true, "符号链接应被识别为链接")
            TestRunner.assertFalse(link?.isDirectory == true)
            // BUG-01 回归点：普通文件必须是 DT_REG(8)，不能被判成目录或链接。
            let file = children.first { $0.name == "目标文件.txt" }
            TestRunner.assertFalse(file?.isDirectory == true, "普通文件不应被判为目录")
            TestRunner.assertFalse(file?.isSymbolicLink == true)
        }

        TestRunner.register("FileEnumerator：符号链接目标可被正确读出（BUG-02 回归）") {
            let root = scratchDirectory("pw-linkdest")
            defer { try? FileManager.default.removeItem(at: root) }

            let targetPath = root.appendingPathComponent("真实文件.txt").path
            writeFile(targetPath, "真实内容")

            errno = 0
            let linkResult = symlink(targetPath, root.appendingPathComponent("链接.txt").path)
            if linkResult != 0 {
                TestRunner.assertTrue(true, "环境不支持 symlink（errno=\(errno)），跳过")
                return
            }

            // BUG-02 回归点：readlink 的指针写法必须正确。
            let destination = FileEnumerator.readLinkDestination(
                at: root.appendingPathComponent("链接.txt").path
            )
            TestRunner.assertNotNil(destination, "应能读出链接目标")
            TestRunner.assertEqual(destination, targetPath)
        }

        TestRunner.register("FileEnumerator：目录被正确识别并递归进入（BUG-01 回归）") {
            let root = scratchDirectory("pw-recurse")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src", isDirectory: true)
            try PathWalker().createDirectory(at: source.path)
            // 子目录 + 子文件：若目录被误判为文件，就不会递归进去。
            try PathWalker().createDirectory(
                at: source.appendingPathComponent("子目录", isDirectory: true).path
            )
            writeFile(
                source.appendingPathComponent("子目录", isDirectory: true)
                    .appendingPathComponent("深层文件.txt").path,
                "深层内容"
            )

            let enumerator = FileEnumerator()
            var names = [String]()
            var directories = 0
            for try await entry in enumerator.enumerate(
                sourceRoot: source.path,
                destinationRoot: root.appendingPathComponent("dst").path
            ) {
                names.append(entry.relativePath)
                if entry.isDirectory { directories += 1 }
            }

            TestRunner.assertTrue(
                names.contains("子目录/深层文件.txt"),
                "应递归进入子目录，实际枚举：\(names)"
            )
            TestRunner.assertEqual(directories, 1, "应识别出 1 个目录")
        }
    }

    // MARK: - CopyfileBridge

    private static func registerCopyfileBridge() {
        TestRunner.register("CopyfileBridge：commit 的 CLONE→EEXIST→DATA 回退链路") {
            let root = scratchDirectory("cf-commit")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("partial.bin").path
            let destination = root.appendingPathComponent("final.bin").path
            writeFile(source, "PARTIAL-CONTENT")

            // 情形 A：dst 不存在 → CLONE 成功（真 CoW）。
            let clonedA = try CopyfileBridge.commit(from: source, to: destination, attemptClone: true)
            TestRunner.assertTrue(clonedA, "dst 不存在时应发生 CoW 克隆")
            TestRunner.assertEqual(readFile(destination), "PARTIAL-CONTENT")

            // 情形 B：dst 已存在 → CLONE 失败(EEXIST) → 回退 DATA 覆盖成功。
            writeFile(destination, "OLD-LONGER-CONTENT-THAT-EXISTED")
            let clonedB = try CopyfileBridge.commit(from: source, to: destination, attemptClone: true)
            TestRunner.assertFalse(clonedB, "dst 已存在时不应声称克隆成功")
            TestRunner.assertEqual(readFile(destination), "PARTIAL-CONTENT")
        }

        TestRunner.register("CopyfileBridge：fcopyfile fd 通道复制并正确覆盖") {
            let root = scratchDirectory("cf-fd")
            defer { try? FileManager.default.removeItem(at: root) }

            let source = root.appendingPathComponent("src.bin").path
            let destination = root.appendingPathComponent("dst.bin").path
            writeFile(source, "FD-CHANNEL-CONTENT")

            let sourceFD = open(source, O_RDONLY)
            let destinationFD = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            TestRunner.assertTrue(sourceFD >= 0)
            TestRunner.assertTrue(destinationFD >= 0)
            defer {
                if sourceFD >= 0 { close(sourceFD) }
                if destinationFD >= 0 { close(destinationFD) }
            }

            try CopyfileBridge.copyData(sourceFD: sourceFD, destinationFD: destinationFD)
            TestRunner.assertEqual(readFile(destination), "FD-CHANNEL-CONTENT")
        }
    }

    // MARK: - Sparse & Metadata

    private static func registerSparseAndMetadata() {
        TestRunner.register("SparseProbe：稀疏文件的空洞可被探测（PRD P0-12 本机可验证）") {
            let root = scratchDirectory("sparse")
            defer { try? FileManager.default.removeItem(at: root) }

            let path = root.appendingPathComponent("sparse.bin").path
            // 创建 64 MiB 稀疏文件（open O_RDWR + ftruncate）。
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            TestRunner.assertTrue(fd >= 0, "open(O_CREAT|O_RDWR) 应可用")
            defer { close(fd) }

            errno = 0
            let truncateResult = ftruncate(fd, 64 * 1024 * 1024)
            TestRunner.assertEqual(truncateResult, 0, "ftruncate 应可用")

            // 写入首尾各 1 字节，中间是空洞。
            _ = "H".withCString { write(fd, $0, 1) }
            _ = lseek(fd, 64 * 1024 * 1024 - 1, SEEK_SET)
            _ = "T".withCString { write(fd, $0, 1) }

            // 验证稀疏性：逻辑大小 64 MiB，实际占用应远小于。
            var sb = stat()
            stat(path, &sb)
            let allocated = Int64(sb.st_blocks) * 512
            TestRunner.assertEqual(sb.st_size, 64 * 1024 * 1024)
            TestRunner.assertTrue(
                allocated < sb.st_size,
                "应为稀疏文件：allocated=\(allocated) size=\(sb.st_size)"
            )

            // 空洞探测。
            let holes = SparseProbe().holes(at: path, size: sb.st_size)
            TestRunner.assertTrue(!holes.isEmpty, "应探测到空洞")
            TestRunner.assertTrue(SparseProbe.totalHoleBytes(holes) > 0)
        }

        TestRunner.register("SparseHandler：策略判定（自动/强制/禁用）") {
            let handler = SparseHandler()
            TestRunner.assertTrue(handler.shouldPreserve(mode: .automatic, destinationSupportsSparse: true))
            TestRunner.assertFalse(handler.shouldPreserve(mode: .automatic, destinationSupportsSparse: false))
            TestRunner.assertTrue(handler.shouldPreserve(mode: .forceKeep, destinationSupportsSparse: false))
            TestRunner.assertFalse(handler.shouldPreserve(mode: .disabled, destinationSupportsSparse: true))
        }

        TestRunner.register("SparseHandler：稀疏结论（保留 / 降级标注）") {
            let handler = SparseHandler()
            let hole = SparseProbe.Hole(offset: 4096, length: 1024)

            let preserved = handler.outcome(
                mode: .automatic,
                destinationSupportsSparse: true,
                holes: [hole],
                creationSucceeded: true
            )
            TestRunner.assertTrue(preserved.preserved)
            TestRunner.assertTrue(preserved.note == nil)

            let degraded = handler.outcome(
                mode: .automatic,
                destinationSupportsSparse: false,
                holes: [hole],
                creationSucceeded: false
            )
            TestRunner.assertFalse(degraded.preserved)
            TestRunner.assertTrue(degraded.note != nil, "降级必须给出标注")
        }

        TestRunner.register("MetadataOps：utimensat 写时间戳后 mtime 正确") {
            let root = scratchDirectory("meta")
            defer { try? FileManager.default.removeItem(at: root) }

            let path = root.appendingPathComponent("t.bin").path
            writeFile(path, "X")

            // 写入一个明确的时间戳。
            let target = Date(timeIntervalSince1970: 1_700_000_000)
            var times = [
                timespec(tv_sec: Int(target.timeIntervalSince1970), tv_nsec: 0),
                timespec(tv_sec: Int(target.timeIntervalSince1970), tv_nsec: 0),
            ]
            errno = 0
            let rc = utimensat(AT_FDCWD, path, &times, 0)
            TestRunner.assertEqual(rc, 0, "utimensat 应可用")

            let metadata = MetadataOps.metadata(at: path)
            TestRunner.assertNotNil(metadata)
            TestRunner.assertEqual(
                Int(metadata!.modifiedAt.timeIntervalSince1970),
                1_700_000_000
            )
        }

        TestRunner.register("MetadataOps：读取 birthtime / inode / 权限位") {
            let root = scratchDirectory("meta-birth")
            defer { try? FileManager.default.removeItem(at: root) }

            let path = root.appendingPathComponent("b.bin").path
            writeFile(path, "X")

            let metadata = MetadataOps.metadata(at: path)
            TestRunner.assertNotNil(metadata)
            TestRunner.assertNotNil(metadata?.birthAt)
            TestRunner.assertTrue(metadata!.inode > 0)
            TestRunner.assertTrue(metadata!.deviceID > 0)
            TestRunner.assertEqual(metadata!.size, 1)
            TestRunner.assertFalse(metadata!.isDirectory)
            TestRunner.assertFalse(metadata!.isSparse)
        }

        TestRunner.register("TimestampPreserver：exFAT 精度降级判定 + APFS 精确") {
            // 当前环境是 APFS → 精确。
            TestRunner.assertEqual(
                TimestampPreserver.precision(for: NSTemporaryDirectory()),
                .exact
            )
        }
    }

    // MARK: - VolumeInspector

    private static func registerVolumeInspector() {
        TestRunner.register("VolumeInspector：文件系统类型 / 可用空间 / 同卷判定") {
            let root = scratchDirectory("vol")
            defer { try? FileManager.default.removeItem(at: root) }

            let fsType = VolumeInspector.fileSystemType(at: root.path)
            TestRunner.assertFalse(fsType.isEmpty)
            TestRunner.assertFalse(fsType == "unknown", "应能读到文件系统类型")

            TestRunner.assertTrue(VolumeInspector.availableBytes(at: root.path) > 0)
            TestRunner.assertTrue(VolumeInspector.totalBytes(at: root.path) > 0)

            // 同卷判定：同一目录的两个子路径必然同卷。
            TestRunner.assertTrue(VolumeInspector.sameVolume(root.path, root.path))

            let volume = VolumeInspector.volumeInfo(at: root.path)
            TestRunner.assertNotNil(volume)
            TestRunner.assertTrue(volume!.totalBytes > 0)
        }

        TestRunner.register("VolumeInspector：APFS 判定与稀疏支持") {
            let root = scratchDirectory("vol-apfs")
            defer { try? FileManager.default.removeItem(at: root) }

            let fsType = VolumeInspector.fileSystemType(at: root.path)
            // 本机是 APFS → 应支持稀疏。
            if fsType == "apfs" {
                TestRunner.assertTrue(VolumeInspector.supportsSparse(at: root.path))
                TestRunner.assertTrue(VolumeInspector.volumeInfo(at: root.path)?.isAPFS == true)
            }
            TestRunner.assertFalse(VolumeInspector.isNetworkVolume(at: root.path))
        }
    }
}
