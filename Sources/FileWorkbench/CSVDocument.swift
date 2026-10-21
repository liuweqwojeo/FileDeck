import Foundation

/// CSV 只负责文本与表格转换；字符编码、文件冲突和原子保存交给 DocumentIO。
enum CSVDelimiter: String, CaseIterable, Sendable {
    case comma = ","
    case semicolon = ";"
    case tab = "\t"

    fileprivate var byte: UInt8 { rawValue.utf8.first! }
}

enum CSVLineEnding: String, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

enum CSVDocumentError: Error, LocalizedError, Equatable {
    case textTooLarge
    case tooManyRows
    case tooManyColumns
    case tooManyCells
    case cellTooLarge(row: Int, column: Int)
    case unterminatedQuotedField(row: Int, column: Int)
    case unexpectedQuote(row: Int, column: Int, byteOffset: Int)
    case characterAfterQuote(row: Int, column: Int, byteOffset: Int)
    case nullCharacter(byteOffset: Int)
    case indexOutOfRange
    case tooManyValues(expected: Int)

    var errorDescription: String? {
        switch self {
        case .textTooLarge: "CSV 文本超过 10 MiB 编辑上限。"
        case .tooManyRows: "CSV 超过 100000 行编辑上限。"
        case .tooManyColumns: "CSV 超过 1024 列编辑上限。"
        case .tooManyCells: "CSV 补齐为矩形后超过 1000000 个单元格编辑上限。"
        case .cellTooLarge(let row, let column): "第 \(row) 行第 \(column) 列超过单个单元格 1 MiB 上限。"
        case .unterminatedQuotedField(let row, let column): "第 \(row) 行第 \(column) 列的双引号未闭合。"
        case .unexpectedQuote(let row, let column, let offset):
            "第 \(row) 行第 \(column) 列在未加引号的字段中包含双引号（UTF-8 字节位置 \(offset)）。"
        case .characterAfterQuote(let row, let column, let offset):
            "第 \(row) 行第 \(column) 列的结束引号后只能出现分隔符或换行（UTF-8 字节位置 \(offset)）。"
        case .nullCharacter(let offset): "CSV 包含空字符（UTF-8 字节位置 \(offset)），无法作为文本表格编辑。"
        case .indexOutOfRange: "单元格、行或列索引超出表格范围。"
        case .tooManyValues(let expected): "输入值超过现有表格维度，最多允许 \(expected) 项。"
        }
    }
}

struct CSVDocument: Equatable, Sendable {
    static let maximumTextBytes = 10 * 1_048_576
    static let maximumCellBytes = 1_048_576
    static let maximumRows = 100_000
    static let maximumColumns = 1_024
    static let maximumCells = 1_000_000

    let delimiter: CSVDelimiter
    private(set) var rows: [[String]]
    private(set) var preferredLineEnding: CSVLineEnding
    // 每条记录保存自己的行尾，保留混合 CR/LF/CRLF；最后一条的 nil 表示没有尾部换行。
    private var lineEndings: [CSVLineEnding?]
    // 表格呈矩形，但未编辑的短行不补写分隔符，避免打开再保存改变原有字段数量。
    private var fieldCounts: [Int]

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.first?.count ?? 0 }
    var hasTrailingNewline: Bool { lineEndings.last.flatMap { $0 } != nil }

    /// 空字符串为 0 行 0 列；空行是一行一个空字段；无行尾的单空字段用双引号编码。
    init(text: String = "", delimiter: CSVDelimiter = .comma) throws {
        guard text.utf8.count <= Self.maximumTextBytes else { throw CSVDocumentError.textTooLarge }
        self.delimiter = delimiter
        rows = []
        lineEndings = []
        fieldCounts = []
        preferredLineEnding = .lf
        try parse(text)
    }

    /// 行列索引从 0 开始。任何校验失败都保持原模型不变，便于界面显示错误后继续编辑。
    mutating func setCell(_ value: String, row: Int, column: Int) throws {
        try validateIndex(row: row, column: column)
        // Swift 的 String 相等会合并 Unicode 规范等价形式；编辑时须按字节判断，保留用户实际输入。
        guard !rows[row][column].utf8.elementsEqual(value.utf8) else { return }
        var updated = self
        updated.rows[row][column] = value
        updated.fieldCounts[row] = max(fieldCounts[row], column + 1)
        try updated.validateContent()
        self = updated
    }

    /// 传入值不足时补空字段；追加行保留原文是否具有尾部换行的习惯。
    mutating func appendRow(_ values: [String] = []) throws {
        let width = rows.isEmpty ? max(1, values.count) : columnCount
        guard values.count <= width else { throw CSVDocumentError.tooManyValues(expected: width) }
        try Self.validateDimensions(rowCount: rowCount + 1, columnCount: width)
        var updated = self
        let trailing = hasTrailingNewline
        if !updated.rows.isEmpty, updated.lineEndings[updated.rowCount - 1] == nil {
            updated.lineEndings[updated.rowCount - 1] = preferredLineEnding
        }
        updated.rows.append(values + Array(repeating: "", count: width - values.count))
        updated.fieldCounts.append(width)
        updated.lineEndings.append(trailing ? preferredLineEnding : nil)
        try updated.validateContent()
        self = updated
    }

    mutating func deleteRow(at index: Int) throws {
        guard rows.indices.contains(index) else { throw CSVDocumentError.indexOutOfRange }
        let trailing = hasTrailingNewline
        rows.remove(at: index)
        fieldCounts.remove(at: index)
        lineEndings.remove(at: index)
        if !rows.isEmpty, !trailing { lineEndings[rowCount - 1] = nil }
        // 删除唯一的宽行后，至少保留一行完整字段数，否则保存再打开会悄悄丢掉空列。
        if !rows.isEmpty, fieldCounts.max() != columnCount { fieldCounts[0] = columnCount }
    }

    /// 空表追加列时创建至少一行；已有表格只能提供不超过现有行数的值。
    mutating func appendColumn(_ values: [String] = []) throws {
        guard rows.isEmpty || values.count <= rowCount else { throw CSVDocumentError.tooManyValues(expected: rowCount) }
        let height = rows.isEmpty ? max(1, values.count) : rowCount
        let width = columnCount + 1
        try Self.validateDimensions(rowCount: height, columnCount: width)
        var updated = self
        if rows.isEmpty {
            updated.rows = (0..<height).map { [$0 < values.count ? values[$0] : ""] }
            updated.fieldCounts = Array(repeating: 1, count: height)
            updated.lineEndings = Array(repeating: preferredLineEnding, count: height)
            updated.lineEndings[height - 1] = nil
        } else {
            for row in 0..<height {
                updated.rows[row].append(row < values.count ? values[row] : "")
                updated.fieldCounts[row] = width
            }
        }
        try updated.validateContent()
        self = updated
    }

    /// 删除唯一列等价于清空表格；不会保留无法用 CSV 表达的“零字段记录”。
    mutating func deleteColumn(at index: Int) throws {
        guard (0..<columnCount).contains(index) else { throw CSVDocumentError.indexOutOfRange }
        if columnCount == 1 {
            rows = []
            fieldCounts = []
            lineEndings = []
            return
        }
        var updated = self
        for row in updated.rows.indices {
            updated.rows[row].remove(at: index)
            if index < updated.fieldCounts[row] { updated.fieldCounts[row] = max(1, updated.fieldCounts[row] - 1) }
        }
        // 删除列也可能增大 CSV：末行“,”变成单空字段时必须写成“\"\"”，仍需在提交前校验上限。
        try updated.validateContent()
        self = updated
    }

    func serialize() throws -> String {
        try validateContent()
        var result = ""
        for row in rows.indices {
            let count = fieldCounts[row]
            for column in 0..<count {
                if column > 0 { result += delimiter.rawValue }
                let value = rows[row][column]
                let forceQuote = count == 1 && value.isEmpty && lineEndings[row] == nil
                if needsQuotes(value) || forceQuote {
                    result += "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                } else {
                    result += value
                }
            }
            result += lineEndings[row]?.rawValue ?? ""
        }
        return result
    }

    private enum ParseState { case unquoted, quoted, closedQuote }

    private mutating func parse(_ text: String) throws {
        let bytes = Array(text.utf8)
        var state = ParseState.unquoted
        var field: [UInt8] = []
        var fields: [String] = []
        var offset = 0
        var recordStarted = false
        var width = 0

        func appendByte(_ byte: UInt8) throws {
            guard field.count < Self.maximumCellBytes else {
                throw CSVDocumentError.cellTooLarge(row: rows.count + 1, column: fields.count + 1)
            }
            field.append(byte)
        }
        func finishField() throws {
            guard fields.count < Self.maximumColumns else { throw CSVDocumentError.tooManyColumns }
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func finishRecord(_ ending: CSVLineEnding?) throws {
            width = max(width, fields.count)
            try Self.validateDimensions(rowCount: rows.count + 1, columnCount: width)
            rows.append(fields)
            fieldCounts.append(fields.count)
            lineEndings.append(ending)
            fields.removeAll(keepingCapacity: true)
        }

        // 分隔符、引号和换行都是 ASCII，以字节扫描可原样保留多字节中文以及引号内的换行。
        while offset < bytes.count {
            let byte = bytes[offset]
            guard byte != 0 else { throw CSVDocumentError.nullCharacter(byteOffset: offset + 1) }
            if state == .quoted {
                if byte == 34 {
                    if offset + 1 < bytes.count, bytes[offset + 1] == 34 {
                        try appendByte(34)
                        offset += 2
                        continue
                    }
                    state = .closedQuote
                } else {
                    try appendByte(byte)
                }
                offset += 1
                continue
            }
            if byte == delimiter.byte {
                try finishField()
                state = .unquoted
                recordStarted = true
            } else if byte == 10 || byte == 13 {
                let ending: CSVLineEnding
                if byte == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 {
                    ending = .crlf
                    offset += 1
                } else {
                    ending = byte == 10 ? .lf : .cr
                }
                if lineEndings.isEmpty { preferredLineEnding = ending }
                try finishField()
                try finishRecord(ending)
                state = .unquoted
                recordStarted = false
            } else if state == .closedQuote {
                throw CSVDocumentError.characterAfterQuote(row: rows.count + 1, column: fields.count + 1, byteOffset: offset + 1)
            } else if byte == 34 {
                guard field.isEmpty else {
                    throw CSVDocumentError.unexpectedQuote(row: rows.count + 1, column: fields.count + 1, byteOffset: offset + 1)
                }
                state = .quoted
                recordStarted = true
            } else {
                try appendByte(byte)
                recordStarted = true
            }
            offset += 1
        }
        guard state != .quoted else {
            throw CSVDocumentError.unterminatedQuotedField(row: rows.count + 1, column: fields.count + 1)
        }
        if recordStarted {
            try finishField()
            try finishRecord(nil)
        }
        for row in rows.indices {
            rows[row].append(contentsOf: repeatElement("", count: width - rows[row].count))
        }
        try validateContent()
    }

    private func validateIndex(row: Int, column: Int) throws {
        guard rows.indices.contains(row), (0..<columnCount).contains(column) else { throw CSVDocumentError.indexOutOfRange }
    }

    private static func validateDimensions(rowCount: Int, columnCount: Int) throws {
        guard rowCount <= maximumRows else { throw CSVDocumentError.tooManyRows }
        guard columnCount <= maximumColumns else { throw CSVDocumentError.tooManyColumns }
        guard rowCount * columnCount <= maximumCells else { throw CSVDocumentError.tooManyCells }
    }

    private func needsQuotes(_ value: String) -> Bool {
        value.utf8.contains { $0 == delimiter.byte || $0 == 34 || $0 == 10 || $0 == 13 }
    }

    private func validateContent() throws {
        try Self.validateDimensions(rowCount: rowCount, columnCount: columnCount)
        var totalBytes = 0
        for row in rows.indices {
            let count = fieldCounts[row]
            totalBytes += count - 1 + (lineEndings[row]?.rawValue.utf8.count ?? 0)
            for column in 0..<count {
                let value = rows[row][column]
                let bytes = value.utf8
                guard bytes.count <= Self.maximumCellBytes else {
                    throw CSVDocumentError.cellTooLarge(row: row + 1, column: column + 1)
                }
                if let null = bytes.firstIndex(of: 0) {
                    throw CSVDocumentError.nullCharacter(byteOffset: bytes.distance(from: bytes.startIndex, to: null) + 1)
                }
                totalBytes += bytes.count
                if needsQuotes(value) || (count == 1 && value.isEmpty && lineEndings[row] == nil) {
                    totalBytes += 2 + bytes.filter { $0 == 34 }.count
                }
                guard totalBytes <= Self.maximumTextBytes else { throw CSVDocumentError.textTooLarge }
            }
        }
    }
}
