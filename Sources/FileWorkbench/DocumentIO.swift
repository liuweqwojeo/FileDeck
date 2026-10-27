import CoreFoundation
import Foundation

/// 编辑器专用的完整文本 I/O。与截断预览分开，防止把预览片段误写回原文件。
enum TextFileEncoding: Equatable, Codable, Sendable {
    case utf8(bom: Bool)
    case utf16LittleEndian
    case utf16BigEndian
    case gb18030

    var name: String {
        switch self {
        case .utf8(let bom): bom ? "UTF-8 BOM" : "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .gb18030: "GB18030"
        }
    }

    fileprivate var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .gb18030:
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
        }
    }

    fileprivate var prefix: Data {
        switch self {
        case .utf8(bom: true): Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        default: Data()
        }
    }
}

struct TextFileDocument: Sendable {
    var text: String
    let encoding: TextFileEncoding
    /// 保留用户打开的路径，包括符号链接；保存时另行核对真实目标。
    var sourceURL: URL? { fileState?.sourceURL }
    var isReadOnly: Bool { fileState?.isReadOnly ?? false }
    /// 编码与 BOM 分开保存：用户可显式打开没有 BOM 的 UTF-16 CSV，普通保存不能悄悄补 BOM。
    fileprivate let byteOrderMark: Data
    fileprivate let fileState: FileSaveState?
}

enum DocumentIOError: Error, LocalizedError {
    case fileTooLarge(limitBytes: Int)
    case notRegularFile
    case unknownEncoding
    case nonRoundTrippableEncoding
    case binaryContent
    case readOnly(URL)
    case externalModification
    case symbolicLinkChanged
    case destinationExists
    case saveLocationRequired
    case cannotEncode(TextFileEncoding)
    case system(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limit): "文件超过 \(limit / 1_048_576) MiB 编辑上限，仅支持只读预览。"
        case .notRegularFile: "此路径不是普通文件，不能开启编辑。"
        case .unknownEncoding: "无法完整解析文件编码；为保护原文件，未开启编辑。"
        case .nonRoundTrippableEncoding: "此编码包含无法逐字节还原的内容，仅支持只读预览；请先另存或转换编码。"
        case .binaryContent: "文件包含二进制内容，不能作为文本编辑。"
        case .readOnly(let url): "没有写入权限：\(url.path)"
        case .externalModification: "文件已被外部修改或移除。请重新加载、另存副本，或明确确认覆盖。"
        case .symbolicLinkChanged: "文件链接的目标已变化，请重新打开文件后再保存。"
        case .destinationExists: "目标文件已存在，请另选位置或明确确认覆盖。"
        case .saveLocationRequired: "新文件需要先选择保存位置。"
        case .cannotEncode(let encoding): "内容不能无损保存为 \(encoding.name)。"
        case .system(let detail): "文件操作失败：\(detail)"
        }
    }
}

enum DocumentIO {
    /// 编辑器必须持有完整内容；此限额包括 BOM，并且同样约束保存后的文件大小。
    static let maximumEditableBytes = 10 * 1_048_576

    static func create(text: String = "", encoding: TextFileEncoding = .utf8(bom: false)) -> TextFileDocument {
        TextFileDocument(text: text, encoding: encoding, byteOrderMark: encoding.prefix, fileState: nil)
    }

    /// 同步方法应由调用方放入后台任务，避免大文件读取或摘要计算阻塞界面。
    static func open(url: URL, encoding: TextFileEncoding? = nil) throws -> TextFileDocument {
        let snapshot = try SafeFileIO.open(url: url, maximumBytes: maximumEditableBytes)
        let decoded = try decode(snapshot.data, requestedEncoding: encoding)
        return TextFileDocument(text: decoded.text, encoding: decoded.encoding,
                                byteOrderMark: decoded.byteOrderMark, fileState: snapshot.state)
    }

    /// 默认拒绝外部变更与已有另存目标。确认覆盖只解除冲突检查，不解除权限和链接目标检查。
    /// 返回新的指纹供下一次保存使用；调用方只能在此方法成功后清除“已修改”状态。
    static func save(_ document: TextFileDocument, to destination: URL? = nil,
                     encoding: TextFileEncoding? = nil,
                     overwriteExternalChanges: Bool = false) throws -> TextFileDocument {
        let outputEncoding = encoding ?? document.encoding
        // 仅显式转码时使用目标编码的默认 BOM；普通保存沿用原文件的实际标记。
        let byteOrderMark = encoding == nil ? document.byteOrderMark : outputEncoding.prefix
        guard let payload = document.text.data(using: outputEncoding.foundationEncoding, allowLossyConversion: false),
              let roundTrip = String(data: payload, encoding: outputEncoding.foundationEncoding),
              roundTrip.utf8.elementsEqual(document.text.utf8) else {
            throw DocumentIOError.cannotEncode(outputEncoding)
        }
        let data = byteOrderMark + payload
        let state = try SafeFileIO.save(data, previous: document.fileState, to: destination,
                                        maximumBytes: maximumEditableBytes,
                                        overwriteExternalChanges: overwriteExternalChanges)
        return TextFileDocument(text: document.text, encoding: outputEncoding,
                                byteOrderMark: byteOrderMark, fileState: state)
    }

    // 递归内容搜索复用同一无损编码/二进制判定，但自行执行有界只读 I/O，不建立保存会话。
    static func decode(_ data: Data, requestedEncoding: TextFileEncoding?) throws
        -> (text: String, encoding: TextFileEncoding, byteOrderMark: Data) {
        let markedEncoding: TextFileEncoding?
        if data.starts(with: [0xFF, 0xFE]) {
            markedEncoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            markedEncoding = .utf16BigEndian
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            markedEncoding = .utf8(bom: true)
        } else {
            markedEncoding = nil
        }
        // BOM 与显式字节编码冲突时不能悄悄解释为另一种文本；UTF-8 的 BOM 选择在保存转码时生效。
        if let markedEncoding, let requestedEncoding,
           markedEncoding.foundationEncoding != requestedEncoding.foundationEncoding {
            throw DocumentIOError.unknownEncoding
        }
        var encoding = markedEncoding ?? requestedEncoding
            ?? (String(data: data, encoding: .utf8) == nil ? .gb18030 : .utf8(bom: false))
        if markedEncoding == nil, case .utf8 = encoding { encoding = .utf8(bom: false) }
        let byteOrderMark = markedEncoding?.prefix ?? Data()
        let payload = Data(data.dropFirst(byteOrderMark.count))
        guard let decoded = String(data: payload, encoding: encoding.foundationEncoding) else { throw DocumentIOError.unknownEncoding }
        // 桥接 NSString 可在显示为 U+FFFD 的同时保留原始孤立代理项，直接调用 data(using:) 会产生“可逆”的假象。
        // 先通过 UTF-8 视图构造原生 Swift 字符串，使检查依据与编辑器实际可操作的 Unicode 内容一致。
        let text = String(decoding: decoded.utf8, as: UTF8.self)
        // Foundation 会把孤立 UTF-16 代理项修复成 U+FFFD，GB18030 也接受部分回编码不同的旧别名。
        // 必须验证逐字节可逆，不能仅以“解码成功”作为可编辑条件；String == 的规范等价也不足以保证字节一致。
        guard text.data(using: encoding.foundationEncoding, allowLossyConversion: false) == payload else {
            throw DocumentIOError.nonRoundTrippableEncoding
        }
        let scalars = text.unicodeScalars
        let controlCount = scalars.filter { $0.value < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C].contains($0.value) }.count
        guard !scalars.contains(where: { $0.value == 0 }), scalars.isEmpty || controlCount * 20 <= scalars.count else {
            throw DocumentIOError.binaryContent
        }
        // 不标准化 CRLF、CR 或混合换行；编辑器应遵循此约定传回原始文本。
        return (text, encoding, byteOrderMark)
    }

}
