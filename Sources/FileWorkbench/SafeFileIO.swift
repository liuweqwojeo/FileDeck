import CryptoKit
import Darwin
import Foundation

/// 文本、PDF 和图片共享保存状态；只有成功的完整读取或保存才能产生此状态。
struct FileSaveState: Sendable {
    let sourceURL: URL
    let isReadOnly: Bool
    fileprivate let resolvedURL: URL
    fileprivate let fingerprint: FileFingerprint
}

struct FileReadResult: Sendable {
    let data: Data
    let state: FileSaveState
}

private struct FileMetadata: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        mode = value.st_mode
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

fileprivate struct FileFingerprint: Equatable, Sendable {
    private let metadata: FileMetadata
    private let digest: Data

    init(data: Data, metadata: stat) {
        self.metadata = FileMetadata(metadata)
        digest = Data(SHA256.hash(data: data))
    }
}

/// 完整文件快照、外部变更检测和原子替换。调用方在后台执行，并按编辑器传入大小限制。
enum SafeFileIO {
    // 媒体编辑持有整份文件；限制峰值内存，超限文件仍可走系统只读预览。
    static let maximumMediaBytes = 256 * 1_048_576

    /// 批量媒体按累计压缩字节预算读取；已有编辑缓冲区也占预算，避免先把所有输入载入内存。
    static func openMediaBatch(urls: [URL], existingBytes: Int = 0,
                               maximumBytes: Int = maximumMediaBytes) throws -> [Data] {
        precondition(maximumBytes > 0 && maximumBytes < Int.max && existingBytes >= 0)
        guard existingBytes <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
        var remaining = maximumBytes - existingBytes
        var result: [Data] = []
        for url in urls {
            guard remaining > 0 else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
            let loaded: FileReadResult
            do { loaded = try open(url: url, maximumBytes: remaining) }
            catch DocumentIOError.fileTooLarge {
                // 错误提示统一为整批预算，不能把随每个输入缩小的剩余额度当作产品上限。
                throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes)
            }
            result.append(loaded.data)
            remaining -= loaded.data.count
        }
        return result
    }

    static func open(url: URL, maximumBytes: Int = maximumMediaBytes) throws -> FileReadResult {
        precondition(maximumBytes > 0 && maximumBytes < Int.max)
        let source = url.standardizedFileURL
        let resolved = source.resolvingSymlinksInPath()
        let snapshot = try readSnapshot(resolved, maximumBytes: maximumBytes)
        guard source.resolvingSymlinksInPath() == resolved else { throw DocumentIOError.symbolicLinkChanged }
        return FileReadResult(data: snapshot.data, state: FileSaveState(
            sourceURL: source, isReadOnly: !isWritable(resolved, metadata: snapshot.metadata),
            resolvedURL: resolved, fingerprint: snapshot.fingerprint))
    }

    /// 新文档 previous 为 nil；保存后必须替换旧状态，不能沿用旧指纹清除编辑状态。
    static func save(_ data: Data, previous: FileSaveState?, to destination: URL? = nil,
                     maximumBytes: Int = maximumMediaBytes,
                     overwriteExternalChanges: Bool = false) throws -> FileSaveState {
        precondition(maximumBytes > 0 && maximumBytes < Int.max)
        guard let source = (destination ?? previous?.sourceURL)?.standardizedFileURL else {
            throw DocumentIOError.saveLocationRequired
        }
        let resolved = source.resolvingSymlinksInPath()
        let savingOriginal = source == previous?.sourceURL
        if savingOriginal, resolved != previous?.resolvedURL { throw DocumentIOError.symbolicLinkChanged }
        guard data.count <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }

        // 即使明确覆盖，也必须完整核对磁盘文件。外部已增大到编辑上限之外时拒绝覆盖，允许另存新路径。
        let existing = try snapshotIfPresent(resolved, maximumBytes: maximumBytes)
        // 明确传入另存目标后允许重建已删除的原路径；普通保存仍报告冲突。
        // 已存在的外部版本仍比较指纹；新出现的文件由最终快照检查和 RENAME_EXCL 保护。
        let recreatingChosenSource = destination != nil && savingOriginal && existing == nil
        if savingOriginal, !overwriteExternalChanges, !recreatingChosenSource, existing?.fingerprint != previous?.fingerprint {
            throw DocumentIOError.externalModification
        }
        if !savingOriginal, existing != nil, !overwriteExternalChanges { throw DocumentIOError.destinationExists }
        if let existing, !isWritable(resolved, metadata: existing.metadata) { throw DocumentIOError.readOnly(source) }
        let parent = resolved.deletingLastPathComponent()
        let parentMetadata = try metadata(at: parent)
        guard isWritable(parent, metadata: parentMetadata) else { throw DocumentIOError.readOnly(parent) }

        // 同目录临时文件保证 rename 不跨卷。直到写入、同步和最后一次冲突检查全部完成，原文件保持不变。
        let temporary = parent.appendingPathComponent(".file-workbench-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        if existing != nil {
            let original = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard original >= 0 else { throw systemError() }
            defer { Darwin.close(original) }
            // 连同 ACL、扩展属性、属主和 POSIX 权限复制，避免原子替换悄悄放宽文件访问范围。
            guard fcopyfile(original, descriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw systemError() }
        }
        // 元数据复制包含旧修改时间；成功保存应让其他应用看到新的修改时间。
        guard futimes(descriptor, nil) == 0 else { throw systemError() }
        guard fsync(descriptor) == 0 else { throw systemError() }
        guard source.resolvingSymlinksInPath() == resolved else { throw DocumentIOError.symbolicLinkChanged }
        let latest = try snapshotIfPresent(resolved, maximumBytes: maximumBytes)
        // 即使用户确认覆盖，也不覆盖“确认后、本次写入过程中”出现的另一轮外部更改。
        guard latest?.fingerprint == existing?.fingerprint else { throw DocumentIOError.externalModification }
        let status: Int32
        if existing == nil {
            // 另存新文件使用内核的排他重命名，避免检查后新出现的文件被覆盖。
            status = renamex_np(temporary.path, resolved.path, UInt32(RENAME_EXCL))
        } else {
            // 普通文件系统没有按内容摘要比较后替换的 API，此处将最后检查紧邻原子替换。
            status = rename(temporary.path, resolved.path)
        }
        guard status == 0 else { throw systemError() }
        var savedMetadata = stat()
        guard fstat(descriptor, &savedMetadata) == 0 else { throw systemError() }
        return FileSaveState(sourceURL: source, isReadOnly: !isWritable(resolved, metadata: savedMetadata),
                             resolvedURL: resolved, fingerprint: FileFingerprint(data: data, metadata: savedMetadata))
    }

    private struct Snapshot {
        let data: Data
        let metadata: stat
        var fingerprint: FileFingerprint { FileFingerprint(data: data, metadata: metadata) }
    }

    private static func snapshotIfPresent(_ url: URL, maximumBytes: Int) throws -> Snapshot? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            if errno == ENOENT { return nil }
            throw systemError()
        }
        return try readSnapshot(url, maximumBytes: maximumBytes)
    }

    private static func readSnapshot(_ url: URL, maximumBytes: Int) throws -> Snapshot {
        // 不跟随在解析后新换入的链接；O_NONBLOCK 防止伪装成文本的管道阻塞线程。
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw systemError() }
        guard before.st_mode & S_IFMT == S_IFREG else { throw DocumentIOError.notRegularFile }
        guard before.st_size <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw DocumentIOError.fileTooLarge(limitBytes: maximumBytes) }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw systemError() }
        // 元数据前后变化或读取不完整时不能建立可保存文档，要求调用方重试完整加载。
        guard FileMetadata(before) == FileMetadata(after), data.count == after.st_size,
              FileMetadata(try metadata(at: url)) == FileMetadata(after) else { throw DocumentIOError.externalModification }
        return Snapshot(data: data, metadata: after)
    }

    private static func metadata(at url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw systemError() }
        return result
    }

    private static func isWritable(_ url: URL, metadata: stat) -> Bool {
        metadata.st_mode & 0o222 != 0 && metadata.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 && access(url.path, W_OK) == 0
    }

    private static func systemError() -> DocumentIOError {
        DocumentIOError.system(String(cString: strerror(errno)))
    }
}
