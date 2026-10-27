import CryptoKit
import Darwin
import Foundation

/// 恢复副本只包含编辑内容与展示信息；原路径不能作为恢复后文档的保存目标或授权。
struct DraftRecoveryCapture: Sendable {
    enum Body: Sendable {
        case text(String, TextFileEncoding, CSVDelimiter?)
        case csv(CSVDocument, original: String?, encoding: TextFileEncoding)
        case binary(Data)
    }
    let kind: WorkbenchFileKind
    let originalURL: URL?
    let title: String
    let body: Body
}

struct DraftRecoveryHeader: Codable, Sendable, Identifiable {
    let version: Int
    let id: UUID
    var owner: UUID
    let kind: String
    let originalPath: String?
    let title: String
    var updatedAt: Date
    let encoding: TextFileEncoding?
    let delimiter: String?
    let payloadBytes: Int
    let digest: String
}

struct DraftRecoveryItem: Sendable, Identifiable {
    let id: UUID
    let header: DraftRecoveryHeader?
    let bytes: Int
    let problem: String?
    var title: String { header?.title ?? "损坏或不兼容的草稿 \(id.uuidString.prefix(8))" }
}

struct DraftRecoveryDocument: Sendable {
    let header: DraftRecoveryHeader
    let data: Data
}

enum DraftRecoveryError: Error, LocalizedError, Equatable {
    case invalidStorage, invalidRecord, incompatible, active, missing, limit, stale
    var errorDescription: String? {
        switch self {
        case .invalidStorage: "恢复目录不可用或包含不安全的链接。草稿仍保留在编辑器内。"
        case .invalidRecord: "恢复副本损坏或校验失败，未打开内容。可保留稍后重试或明确删除。"
        case .incompatible: "此恢复副本来自不支持的版本或格式，未删除。"
        case .active: "此草稿正由另一个 FileDeck 会话使用，请勿重复恢复。"
        case .missing: "此恢复副本已不存在，请刷新列表。"
        case .limit: "恢复存储已达上限（单份 256 MiB、总计 512 MiB、最多 20 份）。已保留上一份副本，请保存文档或清理恢复草稿。"
        case .stale: "草稿已被更新，未应用旧的恢复请求。"
        }
    }
}

/// actor 串行化内容生成与磁盘写入；flock 跨进程协调配额，owner 锁由进程退出自动释放。
/// 单文件带有界 JSON 头和校验正文，临时写入/fsync/rename 后才替换旧副本，崩溃不会安装半份内容。
actor DraftRecoveryStore {
    struct Limits: Sendable {
        var perDraft = 256 * 1_048_576
        var total = 512 * 1_048_576
        var count = 20
        var retention: TimeInterval = 30 * 24 * 60 * 60
    }
    static let shared = DraftRecoveryStore(directory: defaultDirectory)
    static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        // 验收进程必须使用自己的夹具目录，不能读写日常恢复副本。
        for (directory, token) in [("FW_DRAFTS_TEST_ROOT", "FW_DRAFTS_TEST_TOKEN"),
                                   ("FW_OFFICE_SMOKE_DIR", "FW_OFFICE_SMOKE_TOKEN"),
                                   ("FW_MODAL_DOCUMENT_TEST_DIR", "FW_MODAL_DOCUMENT_TEST_TOKEN")] {
            if let value = environment[directory], environment[token]?.isEmpty == false {
                return URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent("DraftRecovery", isDirectory: true)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/FileDeck/DraftRecovery-v1", isDirectory: true)
    }
    let directory: URL
    private let limits: Limits
    private let owner = UUID()
    private var rootFD: Int32 = -1
    private var ownerFD: Int32 = -1
    private var versions: [UUID: UInt64] = [:]
    private static let magic = Data("FWDRFT01".utf8)
    private static let maximumHeader = 16 * 1024
    init(directory: URL, limits: Limits = Limits()) {
        precondition(limits.perDraft > 0 && limits.total > 0 && limits.count > 0 && limits.retention > 0)
        self.directory = directory.standardizedFileURL
        self.limits = limits
    }
    deinit { if ownerFD >= 0 { close(ownerFD) }; if rootFD >= 0 { close(rootFD) } }

    /// generation 由同一宿主递增；迟到保存不能复活已保存/已丢弃的草稿。
    func checkpoint(id: UUID, generation: UInt64, capture: DraftRecoveryCapture?, now: Date = Date()) throws {
        guard generation > versions[id, default: 0] else { return }
        try locked {
            if let existing = try? readHeader(id), existing.owner != owner { throw DraftRecoveryError.active }
            guard let capture else {
                try removeFile(name(id)); versions[id] = generation
                return
            }
            let kind = capture.kind
            guard Self.allowedKinds.contains(kind.rawValue) else { throw DraftRecoveryError.incompatible }
            let data: Data, encoding: TextFileEncoding?, delimiter: String?
            switch capture.body {
            case .text(let text, let selected, let separator):
                data = Data(text.utf8); encoding = selected; delimiter = separator?.rawValue
            case .csv(let model, let original, let selected):
                data = Data(try (original ?? model.serialize()).utf8); encoding = selected; delimiter = model.delimiter.rawValue
            case .binary(let bytes): data = bytes; encoding = nil; delimiter = nil
            }
            guard data.count <= limits.perDraft else { throw DraftRecoveryError.limit }
            let header = DraftRecoveryHeader(version: 1, id: id, owner: owner, kind: kind.rawValue,
                originalPath: capture.originalURL?.path, title: String(capture.title.prefix(255)), updatedAt: now,
                encoding: encoding, delimiter: delimiter, payloadBytes: data.count, digest: Self.digest(data))
            let prefix = try encodeHeader(header)
            let records = try cleanup(now: now)
            let others = records.filter { $0.id != id }
            let bytes = others.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            guard others.count < limits.count, Int64(prefix.count + data.count) <= Int64(limits.total) - bytes else {
                throw DraftRecoveryError.limit
            }
            try write(id: id, prefix: prefix, data: data)
            versions[id] = generation
        }
    }

    func items(now: Date = Date()) throws -> [DraftRecoveryItem] {
        try locked {
            return try cleanup(now: now).filter { item in
                guard let header = item.header else { return true }
                return !isActive(header.owner)
            }.sorted { ($0.header?.updatedAt ?? .distantPast) > ($1.header?.updatedAt ?? .distantPast) }
        }
    }

    /// 在同一进程锁事务中认领，避免两个应用同时恢复同一条记录；打开失败可 relinquish 再次尝试。
    func claim(_ id: UUID) throws -> DraftRecoveryDocument {
        try locked {
            let descriptor = try openRecord(id); defer { close(descriptor) }
            var header = try readHeader(descriptor, id: id)
            guard !isActive(header.owner) else { throw DraftRecoveryError.active }
            let data = try readExactly(descriptor, count: header.payloadBytes)
            guard Self.digest(data) == header.digest else { throw DraftRecoveryError.invalidRecord }
            header.owner = owner
            try write(id: id, prefix: encodeHeader(header), data: data)
            versions[id] = 0
            return DraftRecoveryDocument(header: header, data: data)
        }
    }

    func relinquish(_ id: UUID) throws {
        try locked {
            let descriptor = try openRecord(id); defer { close(descriptor) }
            var header = try readHeader(descriptor, id: id)
            guard header.owner == owner else { return }
            let data = try readExactly(descriptor, count: header.payloadBytes)
            header.owner = UUID() // 没有对应的持有锁，下一次列表可再次恢复。
            try write(id: id, prefix: encodeHeader(header), data: data)
        }
    }

    func delete(_ id: UUID) throws {
        try locked {
            if let header = try? readHeader(id), isActive(header.owner) { throw DraftRecoveryError.active }
            try removeFile(name(id))
        }
    }

    private static let allowedKinds: Set<String> = ["text", "code", "json", "yaml", "markdown", "csv", "pdf", "png", "jpeg", "heic"]
    private func name(_ id: UUID) -> String { id.uuidString + ".fwdraft" }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func prepare() throws {
        if rootFD >= 0 { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DraftRecoveryError.invalidStorage }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), fchmod(descriptor, 0o700) == 0 else {
            close(descriptor); throw DraftRecoveryError.invalidStorage
        }
        rootFD = descriptor

    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try prepare()
        var held = stat(), current = stat()
        guard fstat(rootFD, &held) == 0, lstat(directory.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else { throw DraftRecoveryError.invalidStorage }
        let descriptor = openat(rootFD, ".store-lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DraftRecoveryError.invalidStorage }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, flock(descriptor, LOCK_EX) == 0 else {
            throw DraftRecoveryError.invalidStorage
        }
        defer { flock(descriptor, LOCK_UN) }
        // owner 文件的创建和持锁也在全局事务内，避免另一进程清理尚未来得及 flock 的新 owner。
        if ownerFD < 0 {
            let lock = openat(rootFD, ownerName(owner), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                if lock >= 0 { close(lock) }
                throw DraftRecoveryError.invalidStorage
            }
            ownerFD = lock
        }
        return try operation()
    }
    private func ownerName(_ id: UUID) -> String { ".owner-" + id.uuidString }
    private func isActive(_ id: UUID) -> Bool {
        if id == owner { return true }
        let descriptor = openat(rootFD, ownerName(id), O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno != ENOENT }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { flock(descriptor, LOCK_UN); return false }
        return true // 不确定的锁错误也不能据此窃取仍在编辑的内容。
    }
    private func openRecord(_ id: UUID) throws -> Int32 {
        let descriptor = openat(rootFD, name(id), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw errno == ENOENT ? DraftRecoveryError.missing : DraftRecoveryError.invalidRecord }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_size >= 12, metadata.st_size <= limits.perDraft + Self.maximumHeader + 12 else {
            close(descriptor); throw DraftRecoveryError.invalidRecord
        }
        return descriptor
    }
    private func readHeader(_ id: UUID) throws -> DraftRecoveryHeader {
        let descriptor = try openRecord(id); defer { close(descriptor) }
        return try readHeader(descriptor, id: id)
    }
    private func readHeader(_ descriptor: Int32, id: UUID) throws -> DraftRecoveryHeader {
        let prefix = try readExactly(descriptor, count: 12)
        guard prefix.prefix(8) == Self.magic else { throw DraftRecoveryError.invalidRecord }
        let count = prefix.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Self.maximumHeader else { throw DraftRecoveryError.invalidRecord }
        let header = try JSONDecoder().decode(DraftRecoveryHeader.self, from: readExactly(descriptor, count: count))
        guard header.version == 1, Self.allowedKinds.contains(header.kind) else { throw DraftRecoveryError.incompatible }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, header.id == id, header.payloadBytes >= 0,
              header.payloadBytes <= limits.perDraft, metadata.st_size == 12 + count + header.payloadBytes,
              header.updatedAt.timeIntervalSince1970.isFinite,
              header.digest.count == 64 else { throw DraftRecoveryError.invalidRecord }
        return header
    }
    private func encodeHeader(_ header: DraftRecoveryHeader) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(header)
        guard bytes.count <= Self.maximumHeader else { throw DraftRecoveryError.invalidRecord }
        let count = UInt32(bytes.count)
        return Self.magic + Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + bytes
    }
    private func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw DraftRecoveryError.invalidRecord }
                offset += amount
            }
        }
        return data
    }
    private func write(id: UUID, prefix: Data, data: Data) throws {
        let temporary = ".write-" + UUID().uuidString
        let descriptor = openat(rootFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); unlinkat(rootFD, temporary, 0) }
        for part in [prefix, data] {
            try part.withUnsafeBytes { buffer in
                var offset = 0
                while offset < part.count {
                    let amount = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), part.count - offset)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw posixError() }
                    offset += amount
                }
            }
        }
        guard fsync(descriptor) == 0, renameat(rootFD, temporary, rootFD, name(id)) == 0 else { throw posixError() }
        // 部分文件系统不支持目录 fsync；正文已 fsync + 原子替换，尽力推进目录项持久化。
        _ = fsync(rootFD)
    }
    /// 通过持有的目录 fd 枚举，避免路径在核验后被移走时把另一目录的配额/清理结果混进来。
    private func filenames() throws -> [String] {
        let descriptor = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw posixError() }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw posixError() }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                return names
            }
            let filename = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            if let filename, filename != ".", filename != ".." { names.append(filename) }
        }
    }
    private func scan() throws -> [DraftRecoveryItem] {
        try filenames().compactMap { filename in
            guard filename.hasSuffix(".fwdraft"), let id = UUID(uuidString: String(filename.dropLast(8))), filename == name(id) else { return nil }
            var metadata = stat()
            guard fstatat(rootFD, filename, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            do {
                let header = try readHeader(id)
                return DraftRecoveryItem(id: id, header: header, bytes: Int(metadata.st_size), problem: nil)
            } catch {
                return DraftRecoveryItem(id: id, header: nil, bytes: max(0, Int(metadata.st_size)), problem: error.localizedDescription)
            }
        }
    }
    private func cleanup(now: Date) throws -> [DraftRecoveryItem] {
        let records = try scan()
        var removed: Set<UUID> = []
        for item in records {
            if let header = item.header, now.timeIntervalSince(header.updatedAt) > limits.retention, !isActive(header.owner) {
                try removeFile(name(item.id))
                removed.insert(item.id)
            }
        }
        let remaining = records.filter { !removed.contains($0.id) }
        // 全局锁内没有其他写者；遗留 .write 文件只能是之前崩溃的半份副本。
        let owners = Set(remaining.compactMap { $0.header?.owner })
        for filename in try filenames() {
            if filename.hasPrefix(".write-"), UUID(uuidString: String(filename.dropFirst(7))) != nil { try removeFile(filename) }
            if filename.hasPrefix(".owner-"), let id = UUID(uuidString: String(filename.dropFirst(7))),
               id != owner, !owners.contains(id), !isActive(id) { try removeFile(filename) }
        }
        return remaining
    }
    private func removeFile(_ filename: String) throws {
        guard unlinkat(rootFD, filename, 0) == 0 || errno == ENOENT else { throw posixError() }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
