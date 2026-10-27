import Foundation
import Darwin
import UniformTypeIdentifiers

/// 路径可因重命名变化；设备、inode 与创建时间共同标识磁盘对象，且不解析符号链接。
struct FileIdentity: Hashable, Sendable {
    let device: Int64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

/// 目录列表和目录树共用的只读文件快照；URL 不解析符号链接，避免意外跳出用户选择的目录。
struct FileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let modifiedAt: Date?
    let typeIdentifier: String?
    let identity: FileIdentity?

    init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, isSymbolicLink: Bool,
         size: Int64?, modifiedAt: Date?, typeIdentifier: String?, identity: FileIdentity? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modifiedAt = modifiedAt
        self.typeIdentifier = typeIdentifier
        self.identity = identity
    }

    var id: URL { url }

    /// 应用包、文档包和符号链接只作为文件展示，不允许目录树递归展开。
    var isBrowsableDirectory: Bool {
        isDirectory && !isPackage && !isSymbolicLink
    }
}

enum FileSystemError: LocalizedError {
    case notBrowsableDirectory(URL)

    var errorDescription: String? {
        switch self {
        case let .notBrowsableDirectory(url):
            return "无法浏览“\(url.lastPathComponent)”：请选择普通文件夹。"
        }
    }
}

enum FileSystem {
    static func identity(at url: URL) throws -> FileIdentity {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &metadata) } ?? -1
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return identity(metadata)
    }

    /// vnode 监听用描述符身份核验 F_GETPATH，不能把同名替换目录误认成被重命名的原对象。
    static func identity(ofDescriptor descriptor: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
        return identity(metadata)
    }

    static func identity(_ metadata: stat) -> FileIdentity {
        FileIdentity(device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                     birthSeconds: Int64(metadata.st_birthtimespec.tv_sec),
                     birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec))
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    /// 仅读取当前一层。调用方应在后台任务执行，并将权限、文件消失等错误展示给用户。
    static func entries(at url: URL, showHidden: Bool) throws -> [FileEntry] {
        let directoryURL = url.standardizedFileURL
        guard directoryURL.isFileURL else {
            throw FileSystemError.notBrowsableDirectory(directoryURL)
        }

        let directoryValues = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey
        ])
        guard directoryValues.isDirectory == true,
              !isPackageDirectory(directoryURL, values: directoryValues),
              directoryValues.isSymbolicLink != true else {
            throw FileSystemError.notBrowsableDirectory(directoryURL)
        }

        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )

        // 任一读取失败都向上传递，避免把权限错误伪装成空目录或不完整的成功结果。
        let entries = try urls.map { childURL in
            let values = try childURL.resourceValues(forKeys: resourceKeys)
            let isDirectory = values.isDirectory == true
            return FileEntry(
                url: childURL.standardizedFileURL,
                name: childURL.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: isPackageDirectory(childURL, values: values),
                isSymbolicLink: values.isSymbolicLink == true,
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                typeIdentifier: try typeIdentifier(for: childURL),
                identity: try identity(at: childURL)
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isBrowsableDirectory != rhs.isBrowsableDirectory {
                return lhs.isBrowsableDirectory
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // 本地化比较可能把不同大小写视为相同；增加稳定的次序以免刷新后列表跳动。
            return lhs.url.path < rhs.url.path
        }
    }

    static func folders(at url: URL, showHidden: Bool) throws -> [FileEntry] {
        try entries(at: url, showHidden: showHidden).filter(\.isBrowsableDirectory)
    }

    static func isPackageDirectory(_ url: URL, values: URLResourceValues) -> Bool {
        // RTFD 是目录形式的标准富文本文档；类型服务不可用时仍保留它的文档包语义。
        values.isPackage == true || (values.isDirectory == true && url.pathExtension.lowercased() == "rtfd")
    }

    private static func typeIdentifier(for url: URL) throws -> String? {
        do {
            return try url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
        } catch {
            let nsError = error as NSError
            let serviceError = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
            // LaunchServices 不可用时仅降级可选类型信息；读目录、权限和文件属性错误仍然抛出。
            // -10813 是 kLSDataUnavailableErr，常见于不提供系统类型服务的测试环境。
            if serviceError.domain == NSOSStatusErrorDomain, serviceError.code == -10813 {
                return nil
            }
            throw error
        }
    }
}

extension FileEntry {
    var displaySize: String {
        guard !isDirectory, let size else { return "" }
        return size == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var typeLabel: String {
        if isSymbolicLink { return "符号链接" }
        if isBrowsableDirectory { return "文件夹" }
        if let typeIdentifier, let description = UTType(typeIdentifier)?.localizedDescription { return description }
        return url.pathExtension.isEmpty ? "文件" : "\(url.pathExtension.uppercased()) 文件"
    }
}
