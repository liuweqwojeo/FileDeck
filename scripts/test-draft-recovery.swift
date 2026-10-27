import AppKit
import CryptoKit
import ImageIO
import PDFKit
@preconcurrency import WebKit

/// 父进程在 checkpoint-ready 后 SIGKILL writer，再启动全新 reader；不是只重建内存对象。
@MainActor
final class DraftRecoveryAcceptance: NSObject, NSApplicationDelegate {
    let mode: String
    let output: URL
    var window: NSWindow!
    var hosts: [FWDocumentHost] = []
    var checks: [[String: Any]] = []
    init(mode: String, output: URL) { self.mode = mode; self.output = output }
    enum Failed: Error { case assertion(String) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "FileDeck 草稿崩溃恢复验收（隔离样本）"
        window.contentViewController = NSViewController()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task {
            do { if mode == "writer" { try await writeDrafts() } else { try await recoverDrafts(); finish(true) } }
            catch { checks.append(["check":"执行", "passed":false, "detail":String(describing:error)]); finish(false) }
        }
    }
    func check(_ title: String, _ passed: Bool) throws {
        checks.append(["check":title,"passed":passed]); print("\(passed ? "PASS" : "FAIL") \(title)")
        if !passed { throw Failed.assertion(title) }
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(25))
        }
        throw Failed.assertion("草稿验收等待超时")
    }
    func web(_ view: NSView) -> WKWebView? {
        if let value = view as? WKWebView { return value }
        for child in view.subviews { if let found = web(child) { return found } }
        return nil
    }
    func mount(_ host: FWDocumentHost) async throws {
        hosts.append(host); window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        if host.content is FWTextContent { try await wait { !host.busy && host.canSave } }
    }
    func edit(_ host: FWDocumentHost, _ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            host.smokeReplaceText(text) { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            }
        }
    }
    func png() throws -> Data {
        let context = CGContext(data:nil,width:8,height:4,bitsPerComponent:8,bytesPerRow:8*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.7,blue:0.4,alpha:1))
        context.fill(CGRect(x:0,y:0,width:8,height:4))
        let image = NSBitmapImageRep(cgImage:context.makeImage()!)
        return image.representation(using:.png,properties:[:])!
    }
    let draftText = "# F3 持久草稿\r\n中文😀\r最后一行\n"
    func writeDrafts() async throws {
        let browser = FWBrowserHost(editorView:NSTabView(frame:.zero),openHandler:{ _,_ in },commandHandler:{ _ in })
        window.contentViewController = browser
        window.setContentSize(WorkspaceWindowLayout.welcomeMinimum)
        try await Task.sleep(for:.milliseconds(400))
        window.setContentSize(WorkspaceWindowLayout.welcomeMinimum)
        try await Task.sleep(for:.milliseconds(200))
        try check("欢迎页最小尺寸保持 640×600",abs(browser.view.bounds.width - 640) < 1 && abs(browser.view.bounds.height - 600) < 1)
        try capture(browser.view,name:"welcome-minimum.png")
        window.setContentSize(NSSize(width:1100,height:760))

        let textURL = output.appendingPathComponent("original.md"), csvURL = output.appendingPathComponent("original.csv")
        let pdfURL = output.appendingPathComponent("original.pdf"), imageURL = output.appendingPathComponent("original.png")
        let cleanupURL = output.appendingPathComponent("cleanup.txt")
        try Data("# original\r\nsecond\rlast\n".utf8).write(to:textURL)
        try (Data([255,254]) + "a;b\r\nshort\r\n".data(using:.utf16LittleEndian)!).write(to:csvURL)
        let imageData = try png(); try imageData.write(to:imageURL)
        try PDFOperations.imagesToPDF([imageData,imageData]).write(to:pdfURL)
        try Data("cleanup source".utf8).write(to:cleanupURL)
        let text = try await FWTextContent.open(url:textURL,kind:.markdown)
        let textHost = FWDocumentHost(content:text)
        try await mount(textHost)
        let continuousDeadline = Date().addingTimeInterval(5.5)
        var index = 0
        while Date() < continuousDeadline {
            try await edit(textHost,draftText + String(index)); index += 1
            try await Task.sleep(for:.milliseconds(120))
        }
        let continuousFile = DraftRecoveryStore.defaultDirectory.appendingPathComponent(text.id.uuidString + ".fwdraft")
        try check("连续输入也会生成检查点而不无限等待停笔",FileManager.default.fileExists(atPath:continuousFile.path))
        try await edit(textHost,draftText)
        let csv = try await FWCSVContent.open(url:csvURL,encoding:nil,delimiter:.semicolon)
        let csvHost = FWDocumentHost(content:csv); hosts.append(csvHost)
        try csv.setCell("恢复;值\n第二行",row:0,column:1)
        let pdf = try await FWPDFContent.open(url:pdfURL), pdfHost = FWDocumentHost(content:pdf)
        hosts.append(pdfHost); try pdf.rotate(pageIndexes:[0])
        let image = try await FWImageContent.open(url:imageURL), imageHost = FWDocumentHost(content:image)
        hosts.append(imageHost); try await image.rotate(clockwise:true)
        let cleanup = try await FWTextContent.open(url:cleanupURL,kind:.text), cleanupHost = FWDocumentHost(content:cleanup)
        try await mount(cleanupHost); try await edit(cleanupHost,"cleanup unsaved draft")
        try await wait { self.hosts.count == 5 && self.hosts.allSatisfy { $0.statusText.contains("恢复副本已更新") } }
        try check("五份真实编辑草稿均自动持久化且仍为未保存", hosts.allSatisfy(\.modified))
        let other = DraftRecoveryStore(directory:DraftRecoveryStore.defaultDirectory)
        let visible = try await other.items()
        try check("活跃 writer 的草稿对其他进程恢复入口不可见",visible.isEmpty)
        let records: [String:Any] = ["text":text.id.uuidString,"csv":csv.id.uuidString,"pdf":pdf.id.uuidString,
            "image":image.id.uuidString,"cleanup":cleanup.id.uuidString,
            "sourceFiles":[textURL.path,csvURL.path,pdfURL.path,imageURL.path,cleanupURL.path],
            "expectedText":String(decoding:try text.recoveryCapture!.serializedForAcceptance(),as:UTF8.self),
            "expectedCSV":String(decoding:try csv.recoveryCapture!.serializedForAcceptance(),as:UTF8.self)]
        try JSONSerialization.data(withJSONObject:["passed":true,"mode":mode,"checks":checks],options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("writer-report.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checkpoint-ready.json"),options:.atomic)
        // writer 保持 runloop 和锁，父进程只对这个已核验的子进程发送 SIGKILL。
    }
    func capture(_ view:NSView,name:String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failed.assertion("无法捕获验收视图") }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw Failed.assertion("无法编码验收视图") }
        try data.write(to:output.appendingPathComponent(name))
    }
    func findButton(_ view: NSView, _ title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let found = findButton(child,title) { return found } }
        return nil
    }
    func popup(_ view:NSView) -> NSPopUpButton? {
        if let value = view as? NSPopUpButton { return value }
        for child in view.subviews { if let found = popup(child) { return found } }
        return nil
    }
    func press(_ title: String, selecting: String? = nil) async throws {
        try await wait { self.window.attachedSheet?.contentView.flatMap { self.findButton($0,title) } != nil }
        guard let view = window.attachedSheet?.contentView,let button = findButton(view,title) else { throw Failed.assertion("缺少面板按钮") }
        if let selecting {
            guard let choice = popup(view),let index = choice.itemTitles.firstIndex(where:{$0.hasPrefix(selecting + " · ")}) else { throw Failed.assertion("缺少预期草稿选项") }
            choice.selectItem(at:index)
        }
        if title == "稍后", selecting == nil { try capture(view,name:"recovery-center.png") }
        button.performClick(nil)
    }
    func center() async -> FWDocumentHost? {
        await withCheckedContinuation { continuation in
            FWDocumentHost.presentDraftRecovery(in:window) { continuation.resume(returning:$0) }
        }
    }
    func recoverDrafts() async throws {
        let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("checkpoint-ready.json"))) as! [String:Any]
        let store = DraftRecoveryStore.shared
        let initial = try await store.items()
        try check("SIGKILL 后新进程列出五份草稿且 owner 锁已释放",initial.count == 5)
        let later = Task { try await press("稍后") }
        let skipped = await center(); try await later.value
        let afterLater = try await store.items()
        try check("恢复入口稍后不删除任何副本",skipped == nil && afterLater.count == 5)
        let cancelDelete = Task { try await press("删除所选…",selecting:"cleanup.txt"); try await press("取消"); try await press("稍后") }
        _ = await center(); try await cancelDelete.value
        let afterCancel = try await store.items()
        try check("删除恢复副本二次确认取消保留副本",afterCancel.count == 5)
        let delete = Task { try await press("删除所选…",selecting:"cleanup.txt"); try await press("删除副本"); try await press("稍后") }
        _ = await center(); try await delete.value
        let afterDelete = try await store.items()
        try check("明确删除仅清理选中恢复副本",afterDelete.count == 4 && String(contentsOf:output.appendingPathComponent("cleanup.txt")) == "cleanup source")
        let chooseText = Task { try await press("恢复所选",selecting:"original.md") }
        guard let textHost = await center() else { throw Failed.assertion("恢复入口没有返回文档") }
        try await chooseText.value; try await mount(textHost)
        guard let textWeb = web(textHost.view) else { throw Failed.assertion("恢复文本没有真实 WK") }
        try capture(textHost.view,name:"recovered-text.png")
        let text = try await textWeb.callAsyncJavaScript("return window.workbench.getText()",arguments:[:],in:nil,contentWorld:.page) as? String
        try check("恢复入口打开独立未保存文本并保留实际正文和行尾",textHost.documentURL == nil && textHost.modified && text == metadata["expectedText"] as? String)
        let cancelClose = Task { try await press("取消") }
        let closed = await withCheckedContinuation { continuation in textHost.requestClose(in:output) { continuation.resume(returning:$0) } }
        try await cancelClose.value
        let afterClose = try await textWeb.callAsyncJavaScript("return window.workbench.getText()",arguments:[:],in:nil,contentWorld:.page) as? String
        try check("恢复文本取消关闭保留同一 WK 草稿",!closed && textHost.modified && web(textHost.view) === textWeb && afterClose == text)
        let restoredText = output.appendingPathComponent("recovered.md")
        try await textHost.content.saveAs(to:restoredText,overwriteExternalChanges:false)
        try check("恢复文本另存落盘且不绑定原文件",try String(contentsOf:restoredText) == metadata["expectedText"] as? String && textHost.documentURL == restoredText && !textHost.modified)
        for key in ["csv","pdf","image"] {
            let id = UUID(uuidString:metadata[key] as! String)!
            let host = try await FWDocumentHost.recoverDraft(id)
            try await mount(host)
            try check("恢复 \(key) 为独立未保存可编辑文档",host.documentURL == nil && host.modified && host.canSaveAs && !host.readOnly)
            let ext = key == "image" ? "png" : key
            let target = output.appendingPathComponent("recovered." + ext)
            try await host.content.saveAs(to:target,overwriteExternalChanges:false)
            let data = try Data(contentsOf:target)
            if key == "csv" {
                let opened = try DocumentIO.open(url:target)
                try check("CSV 恢复分号短行换行与 UTF16 编码",opened.encoding == .utf16LittleEndian && opened.text == metadata["expectedCSV"] as? String)
            } else if key == "pdf" {
                let pdf = try PDFOperations.read(data)
                try check("PDF 恢复两页及未保存页面旋转",pdf.pageCount == 2 && pdf.page(at:0)?.rotation == 90)
            } else {
                let image = try ImageOperations.read(data)
                try check("图片恢复真实变换像素而非原文件",image.width == 4 && image.height == 8)
            }
            try check("\(key) 另存成功后推进基线",host.documentURL == target && !host.modified)
        }
        try await wait { (try? FileManager.default.contentsOfDirectory(atPath:DraftRecoveryStore.defaultDirectory.path).filter{$0.hasSuffix(".fwdraft")}.isEmpty) == true }
        try check("全部另存成功后清理对应恢复副本",true)
        try await quotaFailure()
        let external = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("external-sources.json"))) as! [String:String]
        for (filename,digest) in external {
            let url = output.appendingPathComponent(filename)
            if digest == "missing" { try check("原文件删除状态未被恢复过程重建：" + filename,!FileManager.default.fileExists(atPath:url.path)) }
            else { try check("原文件外部版本保持：" + filename,Self.digest(try Data(contentsOf:url)) == digest) }
        }
    }
    func quotaFailure() async throws {
        let source = output.appendingPathComponent("quota.csv")
        try Data("old".utf8).write(to:source)
        let content = try await FWCSVContent.open(url:source,encoding:nil,delimiter:.comma)
        let directory = output.appendingPathComponent("quota-store",isDirectory:true)
        let store = DraftRecoveryStore(directory:directory,limits:.init(perDraft:4))
        try await store.checkpoint(id:content.id,generation:1,capture:.init(kind:.csv,originalURL:source,title:"quota.csv",body:.text("old",.utf8(bom:false),.comma)))
        let record = directory.appendingPathComponent(content.id.uuidString + ".fwdraft")
        let before = try Data(contentsOf:record)
        let host = FWDocumentHost(content:content,recoveryStore:store)
        try await mount(host)
        try content.setCell("over quota",row:0,column:0)
        try await wait { host.statusText.contains("恢复副本未更新") }
        func visibleWarning(_ view:NSView)->Bool {
            if let field = view as? NSTextField,field.stringValue.contains("恢复副本未更新") { return true }
            return view.subviews.contains { visibleWarning($0) }
        }
        try capture(host.view,name:"quota-warning.png")
        try check("超限在真实宿主显示恢复失败且保留dirty",host.modified && visibleWarning(host.view))
        try check("超限保留上一份完整副本和原文件",try Data(contentsOf:record) == before && String(contentsOf:source) == "old")
        let discard = Task { try await press("不保存") }
        let closed = await withCheckedContinuation { continuation in host.requestClose(in:output) { continuation.resume(returning:$0) } }
        try await discard.value
        try check("明确丢弃清理旧恢复副本且不修改原文件",closed && !FileManager.default.fileExists(atPath:record.path) && String(contentsOf:source) == "old")
    }
    static func digest(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    func finish(_ passed:Bool) {
        let report:[String:Any] = ["passed":passed,"mode":mode,"checks":checks,"scope":"real SIGKILL/new process, four native content types, WK draft, recovery/delete/cancel sheets, explicit Save As I/O; no installed-app or Finder UI acceptance"]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(mode + "-report.json"))
        exit(passed ? 0 : 1)
    }
}

extension DraftRecoveryCapture {
    func serializedForAcceptance() throws -> Data {
        switch body {
        case .csv(let model,let original,_): return Data(try (original ?? model.serialize()).utf8)
        case .text(let value,_,_): return Data(value.utf8)
        case .binary(let data): return data
        }
    }
}
@main
struct DraftRecoveryMain {
    static func main() {
        let args = CommandLine.arguments,env = ProcessInfo.processInfo.environment
        guard args.count == 3,["writer","reader"].contains(args[1]),env["FW_DRAFTS_TEST_ROOT"] == args[2],
              env["FW_DRAFTS_TEST_TOKEN"]?.isEmpty == false else { fputs("请运行 scripts/test-draft-recovery.sh\n",stderr); exit(64) }
        let app = NSApplication.shared
        let delegate = DraftRecoveryAcceptance(mode:args[1],output:URL(fileURLWithPath:args[2],isDirectory:true))
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
    }
}
