import AppKit
import ApplicationServices

/// 仅操作令牌绑定的隔离验收进程。按真实 AX 保存/取消按钮，不向产品注入 URL 或完成结果。
@main
struct SystemSavePanelDriver {
    static func fail(_ detail: String) -> NSError {
        NSError(domain: "FileDeck.SystemSavePanelTest", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    static func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value
    }
    static func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root]
        var result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 400 {
            let element = queue.removeFirst()
            if result.contains(where: { CFEqual($0, element) }) { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            result.append(element)
            for key in [kAXChildrenAttribute, kAXWindowsAttribute] {
                queue += attribute(element, key as CFString) as? [AXUIElement] ?? []
            }
        }
        return result
    }
    @MainActor static func run() throws {
        guard CommandLine.arguments.count == 4 else { throw fail("需要 checkpoint、应用路径和本次令牌") }
        let checkpointURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let expectedApp = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let token = CommandLine.arguments[3]
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any]
        guard let request, request["token"] as? String == token, !token.isEmpty,
              let phase = request["phase"] as? String, ["awaiting-cancel", "awaiting-save"].contains(phase),
              let pid = (request["pid"] as? NSNumber)?.int32Value,
              let directory = request["directory"] as? String,
              let filename = request["expectedFileName"] as? String,
              let expectedPath = request["expectedPath"] as? String,
              let title = request["panelTitle"] as? String, !title.isEmpty,
              !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
              URL(fileURLWithPath: directory).standardizedFileURL == checkpointURL.deletingLastPathComponent(),
              URL(fileURLWithPath: expectedPath).standardizedFileURL == checkpointURL.deletingLastPathComponent().appendingPathComponent(filename),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleURL?.standardizedFileURL == expectedApp,
              app.executableURL?.standardizedFileURL == Bundle(url: expectedApp)?.executableURL?.standardizedFileURL,
              ["local.fileworkbench.modal-document-tests", "local.fileworkbench.desktop"].contains(app.bundleIdentifier ?? "") else {
            throw fail("令牌、目标路径或验收进程身份不匹配，拒绝操作")
        }
        guard AXIsProcessTrusted() else { throw fail("缺少 Accessibility 权限，未确认系统面板") }
        app.activate(options: [])
        let root = AXUIElementCreateApplication(pid)
        let all = nodes(root)
        guard let panel = all.first(where: {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String) == "save-panel"
                && ((attribute($0, kAXRoleAttribute as CFString) as? String) == "AXSheet"
                    || (attribute($0, kAXRoleAttribute as CFString) as? String) == "AXWindow")
                && ((attribute($0, kAXTitleAttribute as CFString) as? String) == title
                    || (attribute($0, kAXDescriptionAttribute as CFString) as? String) == title)
        }) else { throw fail("未找到本次标题匹配的真实系统保存面板") }
        let contents = nodes(panel)
        guard let field = contents.first(where: { (attribute($0, kAXIdentifierAttribute as CFString) as? String) == "saveAsNameTextField" }),
              let value = attribute(field, kAXValueAttribute as CFString) as? String,
              [filename, URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent].contains(value) else {
            throw fail("系统面板文件名与临时验收目标不符，拒绝确认")
        }
        let identifier = phase == "awaiting-save" ? "OKButton" : "CancelButton"
        guard let button = contents.first(where: {
            (attribute($0, kAXIdentifierAttribute as CFString) as? String) == identifier
                && (attribute($0, kAXRoleAttribute as CFString) as? String) == "AXButton"
                && (attribute($0, kAXEnabledAttribute as CFString) as? Bool) == true
        }) else { throw fail("真实系统面板按钮不可用") }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else { throw fail("系统按钮 AXPress 失败：\(result.rawValue)") }
        let report: [String: Any] = ["status": "pressed", "pid": pid, "phase": phase,
                                     "buttonIdentifier": identifier, "observedFilename": value,
                                     "panelTitle": title, "expectedPath": expectedPath]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
