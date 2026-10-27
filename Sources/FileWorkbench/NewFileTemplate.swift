import Darwin
import Foundation
import CoreGraphics

/// 浏览器的新建菜单共用格式定义；二进制格式始终来自有效模板或系统编码器。
enum NewFileTemplate: String, CaseIterable, Identifiable, Sendable {
    case folder, word, spreadsheet, presentation, pdf
    case text, markdown, csv, tsv, rtf, json, yaml, xml, html, css, javascript, typescript
    case jsx, tsx, vue, svelte, scss, less, sass
    case python, swift, java, sql, shell, toml, ini
    case c, cpp, cHeader, cppHeader, csharp, go, rust, kotlin, kotlinScript, objectiveC, objectiveCpp
    case php, ruby, dart, lua, r, perl, scala, groovy, julia, powershell, fsharp, visualBasic, clojure, erlang
    case png, jpeg, svg, custom

    var id: String { rawValue }

    // 应用资源在运行期间不变；菜单重绘不必反复检查磁盘，创建时仍重新读取并验证模板。
    static let bundledAvailableTemplates = Set(allCases.filter { $0.isAvailable() })

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .word: "Word 文档 (.docx)"
        case .spreadsheet: "Excel 表格 (.xlsx)"
        case .presentation: "演示文稿 (.pptx)"
        case .pdf: "PDF 文档"
        case .text: "文本文件 (.txt)"
        case .markdown: "Markdown (.md)"
        case .csv: "CSV 表格"
        case .tsv: "TSV 表格"
        case .rtf: "富文本文档 (.rtf)"
        case .json: "JSON"
        case .yaml: "YAML"
        case .xml: "XML"
        case .html: "HTML 网页"
        case .css: "CSS 样式"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .jsx: "React JSX (.jsx)"
        case .tsx: "React TSX (.tsx)"
        case .vue: "Vue 组件 (.vue)"
        case .svelte: "Svelte 组件 (.svelte)"
        case .scss: "SCSS 样式"
        case .less: "Less 样式"
        case .sass: "Sass 样式"
        case .python: "Python"
        case .swift: "Swift"
        case .java: "Java"
        case .sql: "SQL"
        case .shell: "Shell 脚本"
        case .toml: "TOML"
        case .ini: "INI 配置"
        case .c: "C 源文件 (.c)"
        case .cpp: "C++ 源文件 (.cpp)"
        case .cHeader: "C 头文件 (.h)"
        case .cppHeader: "C++ 头文件 (.hpp)"
        case .csharp: "C# (.cs)"
        case .go: "Go (.go)"
        case .rust: "Rust (.rs)"
        case .kotlin: "Kotlin (.kt)"
        case .kotlinScript: "Kotlin 脚本 (.kts)"
        case .objectiveC: "Objective-C (.m)"
        case .objectiveCpp: "Objective-C++ (.mm)"
        case .php: "PHP"
        case .ruby: "Ruby (.rb)"
        case .dart: "Dart"
        case .lua: "Lua"
        case .r: "R"
        case .perl: "Perl (.pl)"
        case .scala: "Scala"
        case .groovy: "Groovy"
        case .julia: "Julia (.jl)"
        case .powershell: "PowerShell (.ps1)"
        case .fsharp: "F# (.fs)"
        case .visualBasic: "Visual Basic (.vb)"
        case .clojure: "Clojure (.clj)"
        case .erlang: "Erlang (.erl)"
        case .png: "PNG 图片"
        case .jpeg: "JPEG 图片"
        case .svg: "SVG 图片"
        case .custom: "自定义扩展名（空白文本）"
        }
    }

    var category: String {
        switch self {
        case .folder: "文件夹"
        case .word, .spreadsheet, .presentation, .pdf, .rtf, .csv, .tsv: "办公文档"
        case .png, .jpeg, .svg: "图片"
        case .custom: "其他"
        case .text, .markdown, .json, .yaml, .xml, .toml, .ini: "文本与配置"
        case .html, .css, .scss, .less, .sass, .javascript, .typescript, .jsx, .tsx, .vue, .svelte: "Web 与样式"
        case .python, .php, .ruby, .lua, .r, .perl, .julia, .shell, .powershell, .sql: "脚本与数据"
        default: "编程语言"
        }
    }

    var fileExtension: String? {
        switch self {
        case .folder, .custom: nil
        case .word: "docx"
        case .spreadsheet: "xlsx"
        case .presentation: "pptx"
        case .text: "txt"
        case .markdown: "md"
        case .javascript: "js"
        case .typescript: "ts"
        case .python: "py"
        case .shell: "sh"
        case .cHeader: "h"
        case .cppHeader: "hpp"
        case .csharp: "cs"
        case .rust: "rs"
        case .kotlin: "kt"
        case .kotlinScript: "kts"
        case .objectiveC: "m"
        case .objectiveCpp: "mm"
        case .ruby: "rb"
        case .perl: "pl"
        case .julia: "jl"
        case .powershell: "ps1"
        case .fsharp: "fs"
        case .visualBasic: "vb"
        case .clojure: "clj"
        case .erlang: "erl"
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    var defaultName: String {
        switch self {
        case .folder: "新建文件夹"
        case .word: "新建文档.docx"
        case .spreadsheet: "新建表格.xlsx"
        case .presentation: "新建演示文稿.pptx"
        case .pdf: "新建文档.pdf"
        case .custom: "新建文件.txt"
        default: "新建文件.\(fileExtension ?? "txt")"
        }
    }

    func isAvailable(resourceDirectory: URL? = Bundle.main.resourceURL) -> Bool {
        !isOffice || officeTemplateURL(resourceDirectory: resourceDirectory) != nil
    }

    fileprivate var isOffice: Bool { self == .word || self == .spreadsheet || self == .presentation }

    fileprivate func officeTemplateURL(resourceDirectory: URL?) -> URL? {
        guard isOffice, let resourceDirectory, let fileExtension else { return nil }
        // 与原生 Office 内核共用随包分发的空白文档，不依赖用户机器安装办公软件。
        for locale in ["zh-CN", "en-US"] {
            let url = resourceDirectory.appendingPathComponent("converter/empty/\(locale)/new.\(fileExtension)")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    fileprivate static func matching(extension value: String) -> NewFileTemplate? {
        let value = value.lowercased()
        // 同一语言的常用后缀共用模板；保留 JSX/TSX、C/C++ 头文件等不同语法的独立入口。
        switch value {
        case "jpeg": return .jpeg
        case "yml": return .yaml
        case "markdown", "mdown": return .markdown
        case "mjs", "cjs": return .javascript
        case "mts", "cts": return .typescript
        case "cc", "cxx", "c++": return .cpp
        case "hh", "hxx", "h++": return .cppHeader
        case "pyw", "pyi": return .python
        case "phtml": return .php
        case "pm": return .perl
        case "sbt": return .scala
        case "gradle": return .groovy
        case "bash", "zsh": return .shell
        case "psm1", "psd1": return .powershell
        case "fsx", "fsi": return .fsharp
        case "cljc": return .clojure
        default: break
        }
        return allCases.first { $0.fileExtension == value }
    }
}

enum NewFileCreationError: LocalizedError {
    case invalidName
    case incorrectExtension(String)
    case directoryChanged
    case unavailableTemplate(String)
    case unsupportedBlankType(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidName: "请输入有效名称，不能包含 /、: 或空字符。"
        case .incorrectExtension(let value): "此模板的文件名需要使用 .\(value) 扩展名。"
        case .directoryChanged: "目标文件夹已移动、替换或不可访问，请重新选择后创建。"
        case .unavailableTemplate(let title): "未找到\(title)的空白模板，请使用完整的 FileDeck 应用。"
        case .unsupportedBlankType(let value): "不能将空白文本创建为 .\(value) 文件，请使用对应软件创建此格式。"
        case .encodingFailed: "无法生成空白文件，请重试。"
        }
    }
}

/// 目录身份来自用户打开新建菜单时的快照。目录描述符固定写入位置，排他创建保留所有同名文件。
enum NewFileCreator {
    static func create(template: NewFileTemplate, name: String, directory: URL,
                       expectedDirectoryIdentity: FileIdentity,
                       resourceDirectory: URL? = Bundle.main.resourceURL) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw NewFileCreationError.invalidName
        }
        // 类型已由用户选择，省略后缀时补齐；显式填写了不兼容的后缀仍拒绝创建。
        let filename = template.fileExtension.flatMap { ext in
            URL(fileURLWithPath: name).pathExtension.isEmpty && !name.hasSuffix(".") ? "\(name).\(ext)" : nil
        } ?? name
        let destination = directory.appendingPathComponent(filename, isDirectory: template == .folder)
        if let ext = template.fileExtension,
           NewFileTemplate.matching(extension: destination.pathExtension) != template {
            throw NewFileCreationError.incorrectExtension(ext)
        }
        let data = template == .folder ? Data() : try contents(for: template, named: filename, resourceDirectory: resourceDirectory)
        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              (try? FileSystem.identity(at: directory)) == expectedDirectoryIdentity else {
            throw NewFileCreationError.directoryChanged
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              !FileSystem.isPackageDirectory(directory, values: values) else {
            throw NewFileCreationError.directoryChanged
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw systemError() }
        defer { Darwin.close(parent) }
        try validateDirectory(parent, at: directory, expected: expectedDirectoryIdentity)
        if template == .folder {
            guard mkdirat(parent, filename, 0o777) == 0 else { throw systemError() }
            return destination
        }

        // 临时文件与最终文件均相对同一目录描述符；即便路径被替换也不会跟随新目录或符号链接。
        let temporary = ".file-workbench-\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { Darwin.close(descriptor); unlinkat(parent, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw systemError() }
        try validateDirectory(parent, at: directory, expected: expectedDirectoryIdentity)
        // RENAME_EXCL 在内核中检查冲突，包含同名目录、普通文件和悬空符号链接。
        guard renameatx_np(parent, temporary, parent, filename, UInt32(RENAME_EXCL)) == 0 else { throw systemError() }
        return destination
    }

    private static func validateDirectory(_ descriptor: Int32, at url: URL, expected: FileIdentity) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(device: Int64(value.st_dev), inode: UInt64(value.st_ino),
                           birthSeconds: Int64(value.st_birthtimespec.tv_sec),
                           birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec)) == expected,
              (try? FileSystem.identity(at: url)) == expected else {
            throw NewFileCreationError.directoryChanged
        }
    }

    private static func contents(for template: NewFileTemplate, named name: String, resourceDirectory: URL?) throws -> Data {
        if template.isOffice {
            guard let url = template.officeTemplateURL(resourceDirectory: resourceDirectory) else {
                throw NewFileCreationError.unavailableTemplate(template.title)
            }
            let data = try SafeFileIO.open(url: url, maximumBytes: 10 * 1_048_576).data
            guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw NewFileCreationError.encodingFailed }
            return data
        }
        switch template {
        case .pdf: return try blankPDF()
        case .png, .jpeg: return try blankImage(jpeg: template == .jpeg)
        case .json: return Data("{}\n".utf8)
        case .yaml: return Data("---\n".utf8)
        case .xml: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root/>\n".utf8)
        case .html: return Data("<!doctype html>\n<html lang=\"zh-CN\">\n<head><meta charset=\"UTF-8\"><title>新建网页</title></head>\n<body>\n</body>\n</html>\n".utf8)
        case .svg: return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\" viewBox=\"0 0 800 600\"></svg>\n".utf8)
        case .rtf: return Data("{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }".utf8)
        case .shell:
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            let interpreter = ["bash", "zsh"].contains(ext) ? ext : "sh"
            return Data("#!/bin/\(interpreter)\n".utf8)
        case .custom:
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            if let known = NewFileTemplate.matching(extension: ext) {
                return try contents(for: known, named: name, resourceDirectory: resourceDirectory)
            }
            // 任意文本扩展名可创建；常见二进制扩展名不能伪装成可打开的空白文档或媒体。
            let binaryExtensions: Set<String> = ["doc", "xls", "ppt", "docm", "xlsm", "pptm", "dotx", "xltx", "potx",
                "pages", "numbers", "key", "odt", "ods", "odp", "heic", "heif", "gif", "bmp", "tif", "tiff", "webp", "ico", "icns", "psd",
                "mp3", "mp4", "m4a", "m4v", "mov", "avi", "wav", "flac", "ogg", "webm", "mkv", "aac",
                "zip", "rar", "7z", "gz", "tar", "bz2", "xz", "dmg", "iso", "exe", "dll", "app", "pkg", "ttf", "woff", "woff2"]
            guard !binaryExtensions.contains(ext) else { throw NewFileCreationError.unsupportedBlankType(ext) }
            return Data()
        default: return Data()
        }
    }

    private static func blankPDF() throws -> Data {
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 页面，单位为 PDF point。
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw NewFileCreationError.encodingFailed
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    private static func blankImage(jpeg: Bool) throws -> Data {
        // 提供可编辑的 800 × 600 白色画布，避免不可见的透明单像素占位图。
        guard let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NewFileCreationError.encodingFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        guard let image = context.makeImage() else { throw NewFileCreationError.encodingFailed }
        return try ImageOperations.export(image, format: jpeg ? .jpeg(quality: 0.9) : .png)
    }

    private static func systemError() -> Error {
        if errno == EEXIST { return DocumentIOError.destinationExists }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
