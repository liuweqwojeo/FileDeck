import Foundation
import UniformTypeIdentifiers

enum WorkbenchFileKind: String, CaseIterable, Sendable {
    case word, spreadsheet, presentation, markdown, text, code, json, yaml, csv
    case pdf, png, jpeg, heic, other, directory
}

enum FileEditorBackend: String, CaseIterable, Sendable {
    case onlyOffice, codeMirror, markdown, csv, pdfKit, imageIO, textPreview, quickLook
}

enum FileOperation: String, CaseIterable, Sendable {
    case create, open, edit, save, saveAs, export
}

/// 这里只描述格式与已接入后端的交集；会话还必须依据实际解码、只读权限和冲突状态收紧操作。
struct FileCapabilities: Equatable, Sendable {
    let kind: WorkbenchFileKind
    let suggestedEditor: FileEditorBackend?
    let activeBackend: FileEditorBackend?
    let operations: Set<FileOperation>
    let saveAsFormats: Set<WorkbenchFileKind>
    let exportFormats: Set<WorkbenchFileKind>
    /// Quick Look 只能尝试预览，不能因有系统预览入口就宣称某个文件一定能显示。
    let isSystemPreviewAttempt: Bool
}

struct FileCapabilityRegistry: Sendable {
    private struct Registration: Sendable {
        let operations: Set<FileOperation>
        let exportFormats: Set<WorkbenchFileKind>
        let isAvailable: Bool
    }

    private var registrations: [FileEditorBackend: Registration] = [:]

    init(includeBuiltInPreviews: Bool = true) {
        if includeBuiltInPreviews {
            register(.textPreview, operations: [.open])
            register(.quickLook, operations: [.open])
        }
    }

    /// 只有能完成文档会话的适配器才应注册；存在处理函数、资源文件或编译通过都不等于编辑器已经接入。
    mutating func register(_ backend: FileEditorBackend, operations: Set<FileOperation>,
                           exportFormats: Set<WorkbenchFileKind> = [], isAvailable: Bool = true) {
        registrations[backend] = Registration(operations: operations, exportFormats: exportFormats, isAvailable: isAvailable)
    }

    mutating func unregister(_ backend: FileEditorBackend) {
        registrations.removeValue(forKey: backend)
    }

    func capabilities(for entry: FileEntry) -> FileCapabilities {
        // 文档包不交给完整文件 I/O；普通目录（含目录链接）也不因名称像文件就获得保存能力。
        if entry.isPackage { return capabilities(for: .other) }
        if entry.isDirectory { return capabilities(for: .directory) }
        return capabilities(for: entry.url, contentType: entry.typeIdentifier.flatMap { UTType($0) })
    }

    /// 纯路由，不访问磁盘、不跟随链接；已有目录快照时优先使用 FileEntry 重载。
    func capabilities(for url: URL, contentType: UTType? = nil) -> FileCapabilities {
        guard url.isFileURL else { return unavailable(kind: .other, suggestedEditor: .quickLook) }
        if let contentType {
            if contentType.conforms(to: .package) { return capabilities(for: .other) }
            if contentType.conforms(to: .folder) { return capabilities(for: .directory) }
        }
        return capabilities(for: Self.kind(for: url, contentType: contentType))
    }

    /// 新建菜单也可按类型查询；后端至少要能 open，孤立的 create/save 声明不能组成可用会话。
    func capabilities(for kind: WorkbenchFileKind) -> FileCapabilities {
        let suggested = Self.suggestedEditor(for: kind)
        var candidates = suggested.map { [$0] } ?? []
        if Self.textKinds.contains(kind) { candidates.append(.textPreview) }
        if kind != .directory { candidates.append(.quickLook) }
        for backend in candidates {
            guard let registration = registrations[backend], registration.isAvailable,
                  registration.operations.contains(.open) else { continue }
            let allowed: Set<FileOperation> = backend == .textPreview || backend == .quickLook
                ? [.open] : Self.editingOperations(for: kind).union([.open])
            var operations = registration.operations.intersection(allowed)
            let exports = operations.contains(.export)
                ? registration.exportFormats.intersection(Self.exportFormats(for: kind)) : []
            if exports.isEmpty { operations.remove(.export) }
            let saveAsFormats: Set<WorkbenchFileKind> = operations.contains(.saveAs)
                ? (Self.imageKinds.contains(kind) ? [.png, .jpeg] : [kind]) : []
            return FileCapabilities(kind: kind, suggestedEditor: suggested, activeBackend: backend,
                                    operations: operations, saveAsFormats: saveAsFormats, exportFormats: exports,
                                    isSystemPreviewAttempt: backend == .quickLook)
        }
        return unavailable(kind: kind, suggestedEditor: suggested)
    }

    private func unavailable(kind: WorkbenchFileKind, suggestedEditor: FileEditorBackend?) -> FileCapabilities {
        FileCapabilities(kind: kind, suggestedEditor: suggestedEditor, activeBackend: nil, operations: [],
                         saveAsFormats: [], exportFormats: [], isSystemPreviewAttempt: false)
    }

    private static let textKinds: Set<WorkbenchFileKind> = [.markdown, .text, .code, .json, .yaml, .csv]
    private static let imageKinds: Set<WorkbenchFileKind> = [.png, .jpeg, .heic]
    private static let sourceExtensions: Set<String> = [
        "xml", "html", "htm", "css", "scss", "less", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte",
        "toml", "ini", "conf", "config", "properties", "env", "sh", "bash", "zsh", "fish", "py", "rb", "php",
        "java", "kt", "kts", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "go", "rs", "sql",
        "graphql", "gql", "proto", "dart", "r", "lua", "pl", "ex", "exs", "erl", "hrl", "clj", "cljs",
        "edn", "scala", "sbt", "gradle", "tex", "bib", "gitignore", "gitattributes", "editorconfig", "dockerignore"
    ]

    private static func suggestedEditor(for kind: WorkbenchFileKind) -> FileEditorBackend? {
        switch kind {
        case .word, .spreadsheet, .presentation: .onlyOffice
        case .markdown: .markdown
        case .text, .code, .json, .yaml: .codeMirror
        case .csv: .csv
        case .pdf: .pdfKit
        case .png, .jpeg, .heic: .imageIO
        case .other: .quickLook
        case .directory: nil
        }
    }

    private static func editingOperations(for kind: WorkbenchFileKind) -> Set<FileOperation> {
        switch kind {
        case .word, .presentation: [.create, .edit, .save, .saveAs, .export]
        case .spreadsheet, .markdown, .text, .code, .json, .yaml, .csv: [.create, .edit, .save, .saveAs]
        case .pdf, .png, .jpeg: [.edit, .save, .saveAs, .export]
        // 图片模型只提供 PNG/JPEG 编码；HEIC 修改后必须另存，不能伪装成原格式保存。
        case .heic: [.edit, .saveAs, .export]
        case .other, .directory: []
        }
    }

    private static func exportFormats(for kind: WorkbenchFileKind) -> Set<WorkbenchFileKind> {
        switch kind {
        case .word, .presentation, .pdf: [.pdf]
        case .png, .jpeg, .heic: [.png, .jpeg, .pdf]
        default: []
        }
    }

    private static func kind(for url: URL, contentType: UTType?) -> WorkbenchFileKind {
        let ext = url.pathExtension.lowercased()
        // 明确扩展名优先于宽泛类型；旧 Office、富文本和 SVG 不因“可预览”而进入未经支持的编辑路径。
        switch ext {
        case "docx": return .word
        case "xlsx": return .spreadsheet
        case "pptx": return .presentation
        case "md", "markdown", "mdown": return .markdown
        case "txt", "text", "log": return .text
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "csv": return .csv
        case "pdf": return .pdf
        case "png": return .png
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif": return .heic
        case "doc", "xls", "ppt", "docm", "xlsm", "pptm", "rtf", "rtfd", "svg", "pages", "numbers", "key": return .other
        default: break
        }
        if sourceExtensions.contains(ext) { return .code }
        let name = url.lastPathComponent.lowercased()
        if ["makefile", "dockerfile", "gemfile", "podfile", ".gitignore", ".gitattributes", ".editorconfig", ".dockerignore"].contains(name)
            || name == ".env" || name.hasPrefix(".env.") { return .code }
        if ["readme", "license", "licence", "notice"].contains(name) { return .text }

        if let type = contentType ?? UTType(filenameExtension: ext) {
            switch type.identifier {
            case "org.openxmlformats.wordprocessingml.document": return .word
            case "org.openxmlformats.spreadsheetml.sheet": return .spreadsheet
            case "org.openxmlformats.presentationml.presentation": return .presentation
            case "net.daringfireball.markdown": return .markdown
            case "public.yaml": return .yaml
            default: break
            }
            if type.conforms(to: .json) { return .json }
            if type.conforms(to: .commaSeparatedText) { return .csv }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
            if type.conforms(to: .sourceCode) { return .code }
            if type.conforms(to: .plainText) { return .text }
        }
        // 沿用现有只读预览对 JSONL、TSV、锁文件等额外文本后缀的识别，不重复维护第二份完整名单。
        return TextPreviewLoader.isTextFile(url) ? .text : .other
    }
}
