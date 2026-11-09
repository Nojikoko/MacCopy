import Foundation

/// BLAKE3 纯 Swift 实现（架构 §1.3 / T03 施工步骤 5）。
///
/// 算法结构（严格对照官方 `c/blake3_portable.c`）：
/// - Block = 64 字节，Chunk = 1024 字节（16 个 Block）
/// - 压缩函数 `compress(cv, block, counter, block_len, flags)`
///   - `state[0..8]`   = 链值 cv
///   - `state[8..12]`  = IV 的**前 4 个** word
///   - `state[12..16]` = 计数器低 32 位 / 计数器高 32 位 / 块长 / 标志位
///   - 7 轮 G 混合，其间做 6 次消息置换
///   - 输出 `out[i] = state[i] ^ state[i+8]`
/// - Merkle 树：Chunk 链值入栈，按需合并为 Parent 节点
///
/// 性能措施（为达成 Q3 的单线程 ≥ 1 GB/s 硬指标）：
/// - **整块直读**：对连续输入的整块直接从调用方缓冲区读取 16 个 word，
///   完全避免「先拷进块缓冲再压缩」的一次内存拷贝
/// - 压缩函数、G 函数、轮函数、消息置换全部 `@inline(__always)`
/// - 直接操作 `UnsafeMutablePointer<UInt32>`，规避数组 COW 检查与边界检查
/// - 链值全程留在 `UnsafeMutablePointer` 中，不做 `[UInt32]` 往返
public struct BLAKE3Hasher: ChecksumAlgorithm {
    /// 算法标识。
    public let id: ChecksumAlgorithmID = .blake3
    /// 中文展示名。
    public let displayName = "BLAKE3"
    /// 摘要字节长度。
    public let digestLength = 32

    /// Block 长度（字节）。
    public static let blockLength = 64
    /// Chunk 长度（字节）。
    public static let chunkLength = 1024
    /// 每个 Chunk 的 Block 数。
    public static let blocksPerChunk = 16
    /// Merkle 栈最大层数（BLAKE3 实际最大 54 层，留余量）。
    public static let maxStackDepth = 64

    /// 预分配的可变缓冲区。
    private let scratch = BLAKE3Scratch()
    /// 当前 Chunk 序号。
    private var chunkCounter: UInt64 = 0
    /// 当前 Chunk 已消耗的字节数。
    private var chunkByteCount: Int = 0
    /// 待定块已缓冲的字节数（0…64）。
    private var blockBytes: Int = 0
    /// 当前 Chunk 已压缩的 Block 数。
    private var blocksCompressed: Int = 0
    /// Merkle 树栈深度。
    private var cvStackDepth: Int = 0

    /// 构造 BLAKE3 计算器。
    public init() {
        reset()
    }

    /// 追加数据。
    public mutating func update(buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty, let base = buffer.baseAddress else { return }

        base.withMemoryRebound(to: UInt8.self, capacity: buffer.count) { bytes in
            var offset = 0
            let total = buffer.count
            while offset < total {
                // 当前 Chunk 已满 → 结算并开新 Chunk。
                if chunkByteCount == Self.chunkLength {
                    finishChunk()
                    startNewChunk(chunkCounter: chunkCounter + 1)
                }

                // 待定块已满 → 压缩它（此时后面肯定还有数据，它不是本 Chunk 的末块）。
                if blockBytes == Self.blockLength {
                    compressPendingBlock()
                }

                // 整块直读路径：连续输入的整块直接从源缓冲读取，省掉一次拷贝。
                if blockBytes == 0 {
                    let blocksLeftInChunk = (Self.chunkLength - chunkByteCount) / Self.blockLength
                    let blocksLeftInSource = (total - offset) / Self.blockLength
                    // 两边各留一块：
                    // - Chunk 侧留末块（末块要带 CHUNK_END，不能提前压缩）
                    // - Source 侧留一块（保证被压缩的块后面确实还有下一个块）
                    let eager = min(blocksLeftInChunk - 1, blocksLeftInSource - 1)
                    if eager > 0 {
                        for index in 0..<eager {
                            let source = UnsafeRawPointer(
                                bytes.advanced(by: offset + index * Self.blockLength)
                            ).assumingMemoryBound(to: UInt32.self)
                            var flags: UInt32 = 0
                            if blocksCompressed == 0 && index == 0 {
                                flags = BLAKE3Constants.flagChunkStart
                            }
                            scratch.compress(
                                source: source,
                                cvIn: scratch.chunkCV,
                                counter: chunkCounter,
                                blockLength: UInt32(Self.blockLength),
                                flags: flags
                            )
                            scratch.copyStateToChunkCV()
                            blocksCompressed += 1
                            chunkByteCount += Self.blockLength
                        }
                        offset += eager * Self.blockLength
                        continue
                    }                }

                // 逐字节路径：填满待定块。
                let space = Self.blockLength - blockBytes
                let take = min(space, total - offset)
                scratch.block.advanced(by: blockBytes)
                    .update(from: bytes.advanced(by: offset), count: take)
                blockBytes += take
                chunkByteCount += take
                offset += take
            }
        }
    }

    /// 计算最终摘要（32 字节）。
    public mutating func finalize() -> [UInt8] {
        // ① 保存当前 Chunk 的链值（= 末块的**输入** CV），再压缩末块得到链值。
        //
        // 关键：根节点的压缩要用「末块压缩前的链值」作为输入 CV，
        // 而不是 IV，也不是末块的输出链值。这是 BLAKE3 实现的第三个易错点。
        scratch.saveRootCV()
        scratch.loadPendingBlockAsMessage()
        scratch.compress(
            source: scratch.rawMessage,
            cvIn: scratch.chunkCV,
            counter: chunkCounter,
            blockLength: UInt32(blockBytes),
            flags: chunkStartFlag | BLAKE3Constants.flagChunkEnd
        )
        scratch.copyStateToChunkCV()

        // ② 自顶向下折叠 Merkle 栈，构造根节点。
        //
        // 官方语义：`output = chunk_output`，
        // 然后 `while 栈非空: output = parent_output(cv_stack[top], output.chaining_value())`。
        // 最顶层（index 0）即根节点，用 ROOT 标志压缩。
        var index = cvStackDepth
        while index > 0 {
            index -= 1
            // 父节点消息 = 左子树链值 || 右子树链值。
            scratch.buildParentMessage(left: scratch.cvStack + index * 8, right: scratch.chunkCV)
            if index == 0 {
                // 最顶层：这就是根节点，用 ROOT 标志压缩。
                scratch.compress(
                    source: scratch.rawMessage,
                    cvIn: scratch.iv,
                    counter: 0,
                    blockLength: UInt32(Self.blockLength),
                    flags: BLAKE3Constants.flagParent | BLAKE3Constants.flagRoot
                )
            } else {
                scratch.compress(
                    source: scratch.rawMessage,
                    cvIn: scratch.iv,
                    counter: 0,
                    blockLength: UInt32(Self.blockLength),
                    flags: BLAKE3Constants.flagParent
                )
                scratch.copyStateToChunkCV()
            }
        }

        // ③ 单 Chunk 情形（栈为空）：根就是当前 Chunk 的末块，需用 ROOT 标志再压一次。
        if cvStackDepth == 0 {
            scratch.loadPendingBlockAsMessage()
            scratch.compress(
                source: scratch.rawMessage,
                cvIn: scratch.rootCV,
                counter: chunkCounter,
                blockLength: UInt32(blockBytes),
                flags: chunkStartFlag | BLAKE3Constants.flagChunkEnd | BLAKE3Constants.flagRoot
            )
        }

        // ④ 取压缩结果的扩展输出（state[8..16]，小端字节序）作为 32 字节摘要。
        //
        // 官方 `root_output_bytes` 取的是 XOF 输出的**前 32 字节**，
        // 即压缩结果中 `out[0..8]`（= state[0..8] ^ state[8..16]）。
        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for wordIndex in 0..<8 {
            let word = scratch.state[wordIndex]
            digest.append(UInt8(word & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 24) & 0xFF))
        }
        return digest
    }

    /// 重置。
    public mutating func reset() {
        scratch.resetCV()
        scratch.clearBlock()
        chunkCounter = 0
        chunkByteCount = 0
        blockBytes = 0
        blocksCompressed = 0
        cvStackDepth = 0
    }

    // MARK: - 内部实现

    /// 当前 Chunk 的起始块标志（仅第一个 Block 带 CHUNK_START）。
    @inline(__always)
    private var chunkStartFlag: UInt32 {
        blocksCompressed == 0 ? BLAKE3Constants.flagChunkStart : 0
    }

    /// 开启新的 Chunk。
    ///
    /// **关键**：必须清零块缓冲。官方 `ChunkState::new` 会把 `buf` 清零；
    /// 若不清零，新 Chunk 的首块会残留上一个 Chunk 末块的内容，导致摘要错误。
    private mutating func startNewChunk(chunkCounter: UInt64) {
        self.chunkCounter = chunkCounter
        chunkByteCount = 0
        blockBytes = 0
        blocksCompressed = 0
        scratch.resetCV()
        scratch.clearBlock()
    }

    /// 结算当前 Chunk（压缩末块并把链值压栈）。
    private mutating func finishChunk() {
        scratch.loadPendingBlockAsMessage()
        scratch.compress(
            source: scratch.rawMessage,
            cvIn: scratch.chunkCV,
            counter: chunkCounter,
            blockLength: UInt32(blockBytes),
            flags: chunkStartFlag | BLAKE3Constants.flagChunkEnd
        )
        // **关键**：把压缩结果写回链值缓冲，后续压栈与折叠都依赖它。
        scratch.copyStateToChunkCV()
        addChunkChainingValue(totalChunks: chunkCounter + 1)
    }

    /// 把当前 Chunk 的链值压栈，按需与已有节点合并（官方 `add_chunk_chaining_value`）。
    private mutating func addChunkChainingValue(totalChunks: UInt64) {
        var count = totalChunks
        while count % 2 == 0 {
            guard cvStackDepth > 0 else { break }
            // 左 = 栈顶，右 = 当前 chunk 链值 → 父节点链值。
            scratch.buildParentMessage(
                left: scratch.cvStack + (cvStackDepth - 1) * 8,
                right: scratch.chunkCV
            )
            scratch.compress(
                source: scratch.rawMessage,
                cvIn: scratch.iv,
                counter: 0,
                blockLength: UInt32(Self.blockLength),
                flags: BLAKE3Constants.flagParent
            )
            // 父节点链值 = 压缩结果前 8 个 word，写回 chunkCV。
            scratch.copyStateToChunkCV()
            cvStackDepth -= 1
            count /= 2
        }
        // 压栈。
        for index in 0..<8 {
            scratch.cvStack[cvStackDepth * 8 + index] = scratch.chunkCV[index]
        }
        cvStackDepth += 1
    }

    /// 压缩待定块（非末块）。
    private mutating func compressPendingBlock() {
        scratch.loadPendingBlockAsMessage()
        scratch.compress(
            source: scratch.rawMessage,
            cvIn: scratch.chunkCV,
            counter: chunkCounter,
            blockLength: UInt32(Self.blockLength),
            flags: chunkStartFlag
        )
        scratch.copyStateToChunkCV()
        blocksCompressed += 1
        blockBytes = 0
        scratch.clearBlock()
    }
}

/// BLAKE3 常量。
enum BLAKE3Constants {
    /// 初始向量（8 个 word）。
    static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    /// 消息置换表（官方 `MSG_PERMUTATION`）。
    static let messagePermutation: [Int] = [
        2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
    ]

    /// 块起始标志。
    static let flagChunkStart: UInt32 = 1
    /// 块结束标志。
    static let flagChunkEnd: UInt32 = 2
    /// 父节点标志。
    static let flagParent: UInt32 = 4
    /// 根节点标志。
    static let flagRoot: UInt32 = 8
}

/// BLAKE3 预分配缓冲区。
///
/// 单独抽出为 class 是为了让 `BLAKE3Hasher` 保持 `Sendable` 值语义：
/// 缓冲区内部可变，通过引用共享，热路径无堆分配。
final class BLAKE3Scratch: @unchecked Sendable {
    /// 64 字节待定块缓冲。
    let block: UnsafeMutableRawPointer
    /// 置换用消息缓冲 A（16 个 word）。
    ///
    /// **注意**：这是 `compress` 的**工作缓冲**，压缩过程中会被就地置换 6 次，
    /// 因此压缩结束后内容已被破坏，不能再当作原始消息使用。
    let messageA: UnsafeMutablePointer<UInt32>
    /// 原始消息缓冲（16 个 word），保存未被置换的原始块。
    let rawMessage: UnsafeMutablePointer<UInt32>
    /// 置换用消息缓冲 B（16 个 word）。
    let alternateMessage: UnsafeMutablePointer<UInt32>
    /// 压缩函数状态（16 个 word）。
    let state: UnsafeMutablePointer<UInt32>
    /// 当前 Chunk 的链值（8 个 word）。
    let chunkCV: UnsafeMutablePointer<UInt32>
    /// IV 常量缓冲（8 个 word）。
    let iv: UnsafeMutablePointer<UInt32>
    /// Merkle 树栈（扁平存储，每层 8 个 word）。
    let cvStack: UnsafeMutablePointer<UInt32>
    /// 根节点用的输入 CV（末块压缩前的链值）。
    let rootCV: UnsafeMutablePointer<UInt32>

    /// 分配缓冲区。
    init() {
        block = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 64)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        messageA = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        messageA.initialize(repeating: 0, count: 16)
        rawMessage = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        rawMessage.initialize(repeating: 0, count: 16)
        alternateMessage = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        alternateMessage.initialize(repeating: 0, count: 16)
        state = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        state.initialize(repeating: 0, count: 16)
        chunkCV = UnsafeMutablePointer<UInt32>.allocate(capacity: 8)
        chunkCV.initialize(repeating: 0, count: 8)
        iv = UnsafeMutablePointer<UInt32>.allocate(capacity: 8)
        iv.initialize(repeating: 0, count: 8)
        for index in 0..<8 {
            iv[index] = BLAKE3Constants.iv[index]
        }
        cvStack = UnsafeMutablePointer<UInt32>.allocate(capacity: BLAKE3Hasher.maxStackDepth * 8)
        cvStack.initialize(repeating: 0, count: BLAKE3Hasher.maxStackDepth * 8)
        rootCV = UnsafeMutablePointer<UInt32>.allocate(capacity: 8)
        rootCV.initialize(repeating: 0, count: 8)
    }

    deinit {
        block.deallocate()
        messageA.deallocate()
        rawMessage.deallocate()
        alternateMessage.deallocate()
        state.deallocate()
        chunkCV.deallocate()
        iv.deallocate()
        cvStack.deallocate()
        rootCV.deallocate()
    }

    /// 保存当前链值到根节点缓冲（末块压缩前的 CV）。
    @inline(__always)
    func saveRootCV() {
        for index in 0..<8 {
            rootCV[index] = chunkCV[index]
        }
    }

    /// 把待定块载入**原始**消息缓冲（小端序解释为 16 个 word）。
    ///
    /// 依赖：arm64 / x86_64 均为小端，字节序与 BLAKE3 要求的 `load32` 一致。
    @inline(__always)
    func loadPendingBlockAsMessage() {
        rawMessage.withMemoryRebound(to: UInt8.self, capacity: 64) { destination in
            destination.update(from: block.assumingMemoryBound(to: UInt8.self), count: 64)
        }
    }

    /// 构造 Parent 节点消息：左链值 || 右链值（写入原始消息缓冲）。
    ///
    /// - Parameters:
    ///   - left: 左子节点链值（8 个 word）。
    ///   - right: 右子节点链值（8 个 word）。
    @inline(__always)
    func buildParentMessage(left: UnsafePointer<UInt32>, right: UnsafePointer<UInt32>) {
        for index in 0..<8 {
            rawMessage[index] = left[index]
            rawMessage[index + 8] = right[index]
        }
    }

    /// 清零 64 字节块缓冲（官方 `memset(self->buf, 0, BLAKE3_BLOCK_LEN)`）。
    @inline(__always)
    func clearBlock() {
        block.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
    }

    /// 把链值恢复为 IV（官方 `chunk_state_reset`）。
    @inline(__always)
    func resetCV() {
        for index in 0..<8 {
            chunkCV[index] = BLAKE3Constants.iv[index]
        }
    }

    /// 把压缩结果（前 8 个 word）复制到当前 Chunk 链值。
    @inline(__always)
    func copyStateToChunkCV() {
        for index in 0..<8 {
            chunkCV[index] = state[index]
        }
    }

    /// 压缩函数（严格对照官方 `compress_pre` + `blake3_compress_in_place_portable`）。
    ///
    /// 官方状态布局（极易记错，是 BLAKE3 实现的第一个坑）：
    /// - `state[0..8]`  = 链值 cv
    /// - `state[8..12]` = IV 的**前 4 个** word
    /// - `state[12]`   = 计数器低 32 位
    /// - `state[13]`   = 计数器高 32 位
    /// - `state[14]`   = 块有效字节长度
    /// - `state[15]`   = 标志位
    ///
    /// 注意：计数器/长度/标志注入的是 **state**，**不是消息块**。
    /// 消息块保持原样，7 轮之间做消息置换。
    ///
    /// 输出：`out[i] = state[i] ^ state[i+8]`，结果留在 `state[0..8]`。
    ///
    /// - Parameters:
    ///   - source: 16 个 word 的消息块。
    ///   - cvIn: 输入链值（8 个 word）。
    ///   - counter: 块计数器。
    ///   - blockLength: 块有效字节长度。
    ///   - flags: 标志位。
    @inline(__always)
    func compress(
        source: UnsafePointer<UInt32>,
        cvIn: UnsafePointer<UInt32>,
        counter: UInt64,
        blockLength: UInt32,
        flags: UInt32
    ) {
        let statePointer = state
        let ivPointer = iv

        // 把消息块载入置换缓冲（64 字节拷贝，相对 7 轮压缩开销可忽略）。
        for index in 0..<16 {
            messageA[index] = source[index]
        }

        // 状态初始化（载入到局部变量，后续全部在寄存器中运算）。
        var s0 = cvIn[0], s1 = cvIn[1], s2 = cvIn[2], s3 = cvIn[3]
        var s4 = cvIn[4], s5 = cvIn[5], s6 = cvIn[6], s7 = cvIn[7]
        var s8 = ivPointer[0], s9 = ivPointer[1], s10 = ivPointer[2], s11 = ivPointer[3]
        var s12 = UInt32(truncatingIfNeeded: counter)
        var s13 = UInt32(truncatingIfNeeded: counter >> 32)
        var s14 = blockLength
        var s15 = flags

        // 7 轮，其间做 6 次消息置换。
        //
        // 置换表用常量下标展开，避免数组的 COW 检查与边界检查（每块 6×16 = 96 次访问）。
        var message = messageA
        var scratchMessage = alternateMessage
        var round = 0
        while round < 7 {
            Self.round(
                &s0, &s1, &s2, &s3, &s4, &s5, &s6, &s7,
                &s8, &s9, &s10, &s11, &s12, &s13, &s14, &s15,
                message
            )
            if round < 6 {
                scratchMessage[0] = message[2]
                scratchMessage[1] = message[6]
                scratchMessage[2] = message[3]
                scratchMessage[3] = message[10]
                scratchMessage[4] = message[7]
                scratchMessage[5] = message[0]
                scratchMessage[6] = message[4]
                scratchMessage[7] = message[13]
                scratchMessage[8] = message[1]
                scratchMessage[9] = message[11]
                scratchMessage[10] = message[12]
                scratchMessage[11] = message[5]
                scratchMessage[12] = message[9]
                scratchMessage[13] = message[14]
                scratchMessage[14] = message[15]
                scratchMessage[15] = message[8]
                swap(&message, &scratchMessage)
            }
            round += 1
        }

        // 写回状态。
        statePointer[0] = s0; statePointer[1] = s1; statePointer[2] = s2; statePointer[3] = s3
        statePointer[4] = s4; statePointer[5] = s5; statePointer[6] = s6; statePointer[7] = s7
        statePointer[8] = s8; statePointer[9] = s9; statePointer[10] = s10; statePointer[11] = s11
        statePointer[12] = s12; statePointer[13] = s13; statePointer[14] = s14; statePointer[15] = s15

        // 输出（严格对照官方 `blake3_compress_in_place_portable`）：
        //
        //   cv_out[i] = state[i] ^ state[i+8]
        //
        // 这 8 个 word 既是链值，也是 32 字节哈希（根哈希取此，小端字节序）。
        for index in 0..<8 {
            statePointer[index] ^= statePointer[index + 8]
        }
    }

    /// 一轮（8 次 G 调用）。
    ///
    /// 运算严格对照官方 `g()` 与 `round_fn()`。
    ///
    /// 性能说明：把 16 个 state word 放在**局部变量**里，用 `inout` 参数传给 G 函数。
    /// 这样编译器能把它们保持在寄存器中，避免每轮 16 次内存 load/store。
    /// （若直接用 `UnsafeMutablePointer` + 下标，编译器必须假设可能别名，
    /// 无法做寄存器分配，这是纯 Swift 版本达不到 1 GB/s 的主因。）
    ///
    /// 下标映射严格对照官方 `round_fn()`：
    /// - 列混合：(0,4,8,12) (1,5,9,13) (2,6,10,14) (3,7,11,15)
    /// - 对角混合：(0,5,10,15) (1,6,11,12) (2,7,8,13) (3,4,9,14)
    @inline(__always)
    static func round(
        _ s0: inout UInt32, _ s1: inout UInt32, _ s2: inout UInt32, _ s3: inout UInt32,
        _ s4: inout UInt32, _ s5: inout UInt32, _ s6: inout UInt32, _ s7: inout UInt32,
        _ s8: inout UInt32, _ s9: inout UInt32, _ s10: inout UInt32, _ s11: inout UInt32,
        _ s12: inout UInt32, _ s13: inout UInt32, _ s14: inout UInt32, _ s15: inout UInt32,
        _ source: UnsafePointer<UInt32>
    ) {
        // Mix the columns.
        g(&s0, &s4, &s8, &s12, source[0], source[1])
        g(&s1, &s5, &s9, &s13, source[2], source[3])
        g(&s2, &s6, &s10, &s14, source[4], source[5])
        g(&s3, &s7, &s11, &s15, source[6], source[7])
        // Mix the diagonals.
        g(&s0, &s5, &s10, &s15, source[8], source[9])
        g(&s1, &s6, &s11, &s12, source[10], source[11])
        g(&s2, &s7, &s8, &s13, source[12], source[13])
        g(&s3, &s4, &s9, &s14, source[14], source[15])
    }

    /// G 函数（官方 `g`）。
    @inline(__always)
    static func g(
        _ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32,
        _ mx: UInt32, _ my: UInt32
    ) {
        a = a &+ b &+ mx
        d = rotateRight(d ^ a, 16)
        c = c &+ d
        b = rotateRight(b ^ c, 12)
        a = a &+ b &+ my
        d = rotateRight(d ^ a, 8)
        c = c &+ d
        b = rotateRight(b ^ c, 7)
    }

    /// 32 位右循环移位。
    @inline(__always)
    static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

extension UnsafeMutableRawPointer {
    /// 从字节指针拷贝指定字节数。
    @inline(__always)
    func update(from source: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        self.copyMemory(from: source, byteCount: count)
    }
}
