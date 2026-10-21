import XCTest
@testable import FileWorkbench

final class CSVDocumentTests: XCTestCase {
    func testQuotedDelimitersEscapesAndMultilineFields() throws {
        let source = "名称,内容,备注\r\n\"张,三\",\"第一行\r\n第二行\",\"他说\"\"你好\"\"\"\r\n"
        let document = try CSVDocument(text: source)
        XCTAssertEqual(document.rows, [["名称", "内容", "备注"], ["张,三", "第一行\r\n第二行", "他说\"你好\""]])
        XCTAssertEqual(document.preferredLineEnding, .crlf)
        XCTAssertTrue(document.hasTrailingNewline)
        XCTAssertEqual(try document.serialize(), source)
        XCTAssertEqual(try CSVDocument(text: document.serialize()).rows, document.rows)
    }

    func testExplicitDelimiterAndWhitespaceRemainLiteral() throws {
        for delimiter in CSVDelimiter.allCases {
            let source = " 左 " + delimiter.rawValue + "右,边;尾\n"
            let input = delimiter == .comma ? " 左 ,\"右,边;尾\"\n" :
                (delimiter == .semicolon ? " 左 ;\"右,边;尾\"\n" : source)
            let document = try CSVDocument(text: input, delimiter: delimiter)
            XCTAssertEqual(document.rows, [[" 左 ", "右,边;尾"]])
            XCTAssertEqual(try CSVDocument(text: document.serialize(), delimiter: delimiter).rows, document.rows)
        }
        XCTAssertEqual(try CSVDocument(text: "a;b", delimiter: .comma).rows, [["a;b"]])
    }

    func testEmptyFileEmptyFieldAndBlankRecordsHaveDistinctEncoding() throws {
        let cases: [(String, [[String]], String)] = [
            ("", [], ""), ("\"\"", [[""]], "\"\""), ("\n", [[""]], "\n"),
            ("\n\n", [[""], [""]], "\n\n"), (",", [["", ""]], ","),
            (",\n", [["", ""]], ",\n"), ("a\n", [["a"]], "a\n"),
            ("a\n\n", [["a"], [""]], "a\n\n"), ("a\n\"\"", [["a"], [""]], "a\n\"\"")
        ]
        for (input, rows, output) in cases {
            let document = try CSVDocument(text: input)
            XCTAssertEqual(document.rows, rows, "输入：\(input.debugDescription)")
            XCTAssertEqual(try document.serialize(), output)
            XCTAssertEqual(try CSVDocument(text: output).rows, rows)
        }
    }

    func testMixedRecordLineEndingsAndRaggedRowsArePreserved() throws {
        let input = "a,b,c\r\nd\re,f\n末行"
        var document = try CSVDocument(text: input)
        XCTAssertEqual(document.rows, [["a", "b", "c"], ["d", "", ""], ["e", "f", ""], ["末行", "", ""]])
        XCTAssertEqual(try document.serialize(), input)
        try document.setCell("新增", row: 1, column: 2)
        XCTAssertEqual(try document.serialize(), "a,b,c\r\nd,,新增\re,f\n末行")
        try document.appendRow(["最后"])
        XCTAssertEqual(try document.serialize(), "a,b,c\r\nd,,新增\re,f\n末行\r\n最后,,")
        XCTAssertFalse(document.hasTrailingNewline)
    }

    func testCellEditPreservesUnicodeNormalizationBytes() throws {
        var document = try CSVDocument(text: "\u{00E9}\r\n")
        try document.setCell("e\u{0301}", row: 0, column: 0)
        // String 相等不能发现本回归；比较 UTF-8 保证规范等价的编辑也确实写入。
        XCTAssertEqual(Array(try document.serialize().utf8), Array("e\u{0301}\r\n".utf8))
        try document.setCell("\u{00E9}", row: 0, column: 0)
        XCTAssertEqual(Array(try document.serialize().utf8), Array("\u{00E9}\r\n".utf8))
    }

    func testRowColumnEditingAndTrailingNewlinePolicy() throws {
        var document = try CSVDocument(text: "a,b\r\nc,d\r\n")
        try document.setCell("a,\"修改\"\n第二行", row: 0, column: 0)
        try document.appendRow(["e"])
        try document.appendColumn(["1", "2", "3"])
        XCTAssertEqual(document.rows, [["a,\"修改\"\n第二行", "b", "1"], ["c", "d", "2"], ["e", "", "3"]])
        try document.deleteRow(at: 1)
        try document.deleteColumn(at: 1)
        XCTAssertEqual(document.rows, [["a,\"修改\"\n第二行", "1"], ["e", "3"]])
        XCTAssertEqual(try document.serialize(), "\"a,\"\"修改\"\"\n第二行\",1\r\ne,3\r\n")
        XCTAssertTrue(document.hasTrailingNewline)
        XCTAssertEqual(try CSVDocument(text: document.serialize()).rows, document.rows)
    }

    func testEmptyTableStructuralOperations() throws {
        var document = try CSVDocument()
        XCTAssertEqual(document.columnCount, 0)
        try document.appendRow()
        XCTAssertEqual(try document.serialize(), "\"\"")
        try document.deleteColumn(at: 0)
        XCTAssertEqual(try document.serialize(), "")
        try document.appendColumn(["一", "二"])
        XCTAssertEqual(try document.serialize(), "一\n二")
        try document.deleteRow(at: 1)
        XCTAssertEqual(try document.serialize(), "一")
        try document.deleteRow(at: 0)
        XCTAssertEqual(document.rowCount, 0)
        XCTAssertEqual(document.columnCount, 0)
    }

    func testDeletingOnlyWideRowKeepsEmptyColumnsOnRoundTrip() throws {
        var document = try CSVDocument(text: "a,b,c\nx\ny")
        try document.deleteRow(at: 0)
        XCTAssertEqual(document.columnCount, 3)
        XCTAssertEqual(try document.serialize(), "x,,\ny")
        XCTAssertEqual(try CSVDocument(text: document.serialize()).rows, document.rows)
    }

    func testMalformedQuoteErrorsIdentifyRecordAndField() {
        assertError("a,b\n1,\"未闭合", .unterminatedQuotedField(row: 2, column: 2))
        assertError("a,b\n1,x\"", .unexpectedQuote(row: 2, column: 2, byteOffset: 8))
        assertError("a,b\n1,\"x\"z", .characterAfterQuote(row: 2, column: 2, byteOffset: 10))
        assertError("\"a\" ", .characterAfterQuote(row: 1, column: 1, byteOffset: 4))
        assertError("a\0b", .nullCharacter(byteOffset: 2))
    }

    func testInvalidEditsAreAtomic() throws {
        var document = try CSVDocument(text: "a,b\nc,d")
        let original = document
        XCTAssertThrowsError(try document.setCell("x", row: 2, column: 0))
        XCTAssertThrowsError(try document.setCell("x", row: 0, column: -1))
        XCTAssertThrowsError(try document.appendRow(["1", "2", "3"]))
        XCTAssertThrowsError(try document.appendColumn(["1", "2", "3"]))
        XCTAssertThrowsError(try document.deleteRow(at: -1))
        XCTAssertThrowsError(try document.deleteColumn(at: 2))
        XCTAssertThrowsError(try document.setCell("\0", row: 0, column: 0))
        XCTAssertThrowsError(try document.setCell(String(repeating: "x", count: CSVDocument.maximumCellBytes + 1), row: 0, column: 0))
        XCTAssertEqual(document, original)
    }

    func testSizeAndDimensionLimitsRejectBeforePadding() throws {
        assertError(String(repeating: "x", count: CSVDocument.maximumTextBytes + 1), .textTooLarge)
        assertError(String(repeating: "x", count: CSVDocument.maximumCellBytes + 1), .cellTooLarge(row: 1, column: 1))
        assertError(String(repeating: ",", count: CSVDocument.maximumColumns), .tooManyColumns)
        assertError(String(repeating: "\n", count: CSVDocument.maximumRows + 1), .tooManyRows)
        // 只需很小的源文本即可产生巨大的补齐表格，必须按矩形规模校验而非源字节大小。
        let sparse = String(repeating: ",", count: 1_000) + "\n" + String(repeating: "x\n", count: 1_000)
        assertError(sparse, .tooManyCells)
    }

    func testEscapingExpansionEnforcesSerializedLimitAndKeepsOriginal() throws {
        let field = String(repeating: "a", count: CSVDocument.maximumCellBytes)
        var document = try CSVDocument(text: Array(repeating: field, count: 9).joined(separator: ","))
        let original = document
        let quotes = String(repeating: "\"", count: CSVDocument.maximumCellBytes)
        XCTAssertThrowsError(try document.setCell(quotes, row: 0, column: 0)) { error in
            XCTAssertEqual(error as? CSVDocumentError, .textTooLarge)
        }
        XCTAssertEqual(document, original)
    }

    func testDeletingColumnRejectsEscapingExpansionWithoutChangingDocument() throws {
        let fullField = String(repeating: "a", count: CSVDocument.maximumCellBytes)
        let text = String(repeating: fullField + "\n", count: 9)
            + String(repeating: "b", count: CSVDocument.maximumCellBytes - 11) + "\n,"
        XCTAssertEqual(text.utf8.count, CSVDocument.maximumTextBytes)
        var document = try CSVDocument(text: text)
        // 不齐整的前十行没有此列；末行删除后从逗号变成两个引号，会比原文件增加一个字节。
        XCTAssertThrowsError(try document.deleteColumn(at: 1)) { error in
            XCTAssertEqual(error as? CSVDocumentError, .textTooLarge)
        }
        XCTAssertEqual(document.columnCount, 2)
        XCTAssertTrue(try document.serialize().utf8.elementsEqual(text.utf8))
    }

    private func assertError(_ text: String, _ expected: CSVDocumentError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CSVDocument(text: text), file: file, line: line) { error in
            XCTAssertEqual(error as? CSVDocumentError, expected, file: file, line: line)
        }
    }
}
