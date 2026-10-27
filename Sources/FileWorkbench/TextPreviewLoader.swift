import CoreFoundation
import Foundation
import UniformTypeIdentifiers

struct TextPreviewDocument: Sendable {
    let text: String
    let encodingName: String
    let isTruncated: Bool
    let bytesRead: Int
}

enum PreparedFilePreview: Sendable {
    case text(TextPreviewDocument)
    case media
    case quickLook
}

enum FilePreviewFailure: Error, LocalizedError, Sendable {
    case permissionDenied
    case directory
    case specialFile
    case binaryContent
    case unknownEncoding
    case cancelled
    case unreadable(String)

    /// 内容或编码不在内置预览能力内，并不代表磁盘文件损坏；I/O 错误保留独立的重试路径。
    var isUnsupported: Bool {
        switch self {
        case .directory, .specialFile, .binaryContent, .unknownEncoding: true
        case .permissionDenied, .cancelled, .unreadable: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有权限读取此文件。请重新选择其所在目录，或在系统设置中检查文件访问权限。"
        case .directory:
            "这是一个文件夹。请在中间列表中选择文件进行预览。"
        case .specialFile:
            "此项目不是普通文件，暂不支持内嵌预览。"
        case .binaryContent:
            "文件包含二进制内容，无法作为文本显示。可以尝试使用默认应用打开。"
        case .unknownEncoding:
            "未能识别此文件的文本编码。可以使用默认应用查看或转换为 UTF-8。"
        case .cancelled:
            "预览已取消。"
        case .unreadable(let detail):
            "无法读取文件：\(detail)"
        }
    }
}

enum TextPreviewLoader {
    static let maximumBytes = 1_048_576

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "log", "csv", "tsv", "json", "jsonl",
        "ndjson", "xml", "html", "htm", "css", "scss", "less", "js", "jsx", "ts", "tsx",
        "mjs", "cjs", "vue", "svelte", "yaml", "yml", "toml", "ini", "conf", "config",
        "properties", "env", "sh", "bash", "zsh", "fish", "py", "rb", "php", "java",
        "kt", "kts", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "go",
        "rs", "sql", "graphql", "gql", "proto", "dart", "r", "lua", "pl", "ex", "exs",
        "erl", "hrl", "clj", "cljs", "edn", "scala", "sbt", "gradle", "tex", "bib",
        "ipynb", "gitignore", "gitattributes", "editorconfig", "dockerignore", "lock",
        "sass", "mts", "cts", "cxx", "c++", "hh", "hxx", "h++", "pyw", "pyi", "phtml", "pm", "groovy", "jl",
        "ps1", "psm1", "psd1", "fs", "fsx", "fsi", "vb", "cljc"
    ]

    static func isTextFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if ["readme", "license", "licence", "notice", "makefile", "dockerfile", "gemfile", "podfile", "rakefile", "jenkinsfile"].contains(name) {
            return true
        }
        if name.hasPrefix(".env") || [".gitignore", ".gitattributes", ".editorconfig", ".dockerignore"].contains(name) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        // 富文本和 SVG 保留系统的排版/图像预览，不降级为源文本。
        guard !["rtf", "rtfd", "svg"].contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .plainText) || type.conforms(to: .sourceCode)
    }

    static func prepare(url: URL) async -> Result<PreparedFilePreview, FilePreviewFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        // 文件句柄、编码探测全部放到后台；快速切换选中项时不阻塞主线程。
        let task = Task.detached(priority: .userInitiated) {
            prepareSynchronously(url: url)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func prepareSynchronously(url: URL) -> Result<PreparedFilePreview, FilePreviewFailure> {
        do {
            try Task.checkCancellation()
            let resolvedURL = url.resolvingSymlinksInPath()
            let values = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey])
            // RTFD 等文档包在磁盘上是目录，但属于系统可预览文档，不按普通目录拒绝。
            if FileSystem.isPackageDirectory(resolvedURL, values: values) { return .success(.quickLook) }
            if values.isDirectory == true { return .failure(.directory) }
            // 不打开管道/设备等特殊文件，以免一次预览无限等待。
            guard values.isRegularFile == true else { return .failure(.specialFile) }

            let handle = try FileHandle(forReadingFrom: resolvedURL)
            defer { try? handle.close() }
            try Task.checkCancellation()
            guard isTextFile(url) else {
                // 播放列表可能引用网络或授权范围以外的文件，不交给本地媒体播放器自动解析。
                let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
                return .success(mediaExtensions.contains(url.pathExtension.lowercased()) ? .media : .quickLook)
            }

            // 多读 1 字节判断截断，不根据可能变化的文件大小一次性加载整个文件。
            let buffer = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            let truncated = buffer.count > maximumBytes
            let data = Data(buffer.prefix(maximumBytes))
            let document = try decode(data, truncated: truncated)
            try Task.checkCancellation()
            return .success(.text(document))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let failure as FilePreviewFailure {
            return .failure(failure)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoPermission.rawValue {
                return .failure(.permissionDenied)
            }
            if nsError.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(nsError.code)) {
                return .failure(.permissionDenied)
            }
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    static func decode(_ data: Data, truncated: Bool) throws -> TextPreviewDocument {
        let bytes = Array(data.prefix(4))
        let payload: Data
        let encodings: [(String.Encoding, String)]
        if bytes.starts(with: [0xFF, 0xFE]) {
            payload = Data(data.dropFirst(2))
            encodings = [(.utf16LittleEndian, "UTF-16 LE")]
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            payload = Data(data.dropFirst(2))
            encodings = [(.utf16BigEndian, "UTF-16 BE")]
        } else {
            payload = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
            let sample = payload.prefix(8_192)
            let controlCount = sample.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C].contains($0) }.count
            guard !sample.contains(0), sample.isEmpty || controlCount * 20 <= sample.count else {
                throw FilePreviewFailure.binaryContent
            }
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
            encodings = [(.utf8, "UTF-8"), (gb18030, "GB18030")]
        }

        for (encoding, label) in encodings {
            // 字节上限可能落在多字节字符中间，仅在截断时允许丢弃末尾最多 3 字节。
            for removedBytes in 0...(truncated ? min(3, payload.count) : 0) {
                let candidate = removedBytes == 0 ? payload : Data(payload.dropLast(removedBytes))
                if let text = String(data: candidate, encoding: encoding) {
                    guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                        throw FilePreviewFailure.binaryContent
                    }
                    return TextPreviewDocument(text: text, encodingName: label, isTruncated: truncated, bytesRead: data.count)
                }
            }
        }
        throw FilePreviewFailure.unknownEncoding
    }
}
