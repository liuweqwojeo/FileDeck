import Foundation
import PDFKit

/// 使用完整应用的真实 Office 模板验证浏览器新建结果；只在调用方指定的隔离目录写入。
@main
enum FileCreationAcceptance {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("用法：FileCreationAcceptance <完整应用路径> <新建验收目录>\n", stderr)
            exit(64)
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        do { try run(app: app, output: output) }
        catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(app: URL, output: URL) throws {
        let resources = app.appendingPathComponent("Contents/Resources")
        let identity = try FileSystem.identity(at: output)
        var results: [[String: Any]] = []
        let officeParts: [(NewFileTemplate, [String: String])] = [
            (.word, ["word/document.xml": "document"]),
            (.spreadsheet, ["xl/workbook.xml": "workbook", "xl/worksheets/sheet1.xml": "worksheet"]),
            (.presentation, ["ppt/presentation.xml": "presentation", "ppt/slides/slide1.xml": "sld"])
        ]
        for (template, parts) in officeParts {
            let file = try NewFileCreator.create(template: template, name: template.defaultName,
                                                  directory: output, expectedDirectoryIdentity: identity,
                                                  resourceDirectory: resources)
            let ext = file.pathExtension
            let source = try requireTemplate(ext, resources: resources)
            let created = try Data(contentsOf: file)
            try require(created == Data(contentsOf: source), "\(ext)：与源模板逐字节相同")
            _ = try unzip(["-t", file.path])
            let entries = Set(try unzip(["-Z1", file.path]).split(separator: "\n").map(String.init))
            for part in ["[Content_Types].xml", "_rels/.rels"] + Array(parts.keys) {
                try require(entries.contains(part), "\(ext)：包含 \(part)")
            }
            for (part, rootName) in parts {
                let data = Data(try unzip(["-p", file.path, part]).utf8)
                let xml = try XMLDocument(data: data)
                try require(xml.rootElement()?.localName == rootName, "\(ext)：\(part) 可解析为 \(rootName)")
            }
            results.append(["format": ext, "file": file.path, "template": source.path,
                            "bytes": created.count, "byteIdentical": true, "zipVerified": true,
                            "corePartsVerified": Array(parts.keys).sorted(), "passed": true])
            print("PASS \(ext.uppercased())：真实模板新建、逐字节一致、ZIP 完整性和 OOXML 核心部件")
        }
        let pdf = try NewFileCreator.create(template: .pdf, name: "空白文档.pdf", directory: output,
                                             expectedDirectoryIdentity: identity, resourceDirectory: resources)
        let document = try PDFOperations.read(Data(contentsOf: pdf))
        try require(document.pageCount == 1, "PDF：可打开且包含一页")
        try require(document.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 595, height: 842),
                    "PDF：A4 页面尺寸")
        results.append(["format": "pdf", "file": pdf.path, "pages": document.pageCount, "passed": true])
        print("PASS PDF：实际新建文件可解码为一页 A4 文档")
        for template in [NewFileTemplate.png, .jpeg] {
            let file = try NewFileCreator.create(template: template, name: template.defaultName,
                                                  directory: output, expectedDirectoryIdentity: identity,
                                                  resourceDirectory: resources)
            let image = try ImageOperations.read(Data(contentsOf: file))
            try require(image.width == 800 && image.height == 600, "\(template.rawValue)：800 × 600 图片可打开")
            results.append(["format": template.rawValue, "file": file.path, "width": image.width,
                            "height": image.height, "passed": true])
            print("PASS \(template.rawValue.uppercased())：实际新建图片可解码为 800 × 600 像素")
        }
        let report: [String: Any] = ["application": app.path, "passed": true,
                                     "checks": results, "formatCount": results.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func requireTemplate(_ ext: String, resources: URL) throws -> URL {
        for locale in ["zh-CN", "en-US"] {
            let url = resources.appendingPathComponent("converter/empty/\(locale)/new.\(ext)")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        throw NSError(domain: "FileCreationAcceptance", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "缺少真实 \(ext) 模板"])
    }

    private static func require(_ condition: Bool, _ description: String) throws {
        guard condition else {
            throw NSError(domain: "FileCreationAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: description])
        }
    }

    private static func unzip(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try require(process.terminationStatus == 0, "unzip 验证失败：\(text)")
        return text
    }
}
