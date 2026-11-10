import Foundation
import XCTest
@testable import FileWorkbench

/// 搜索集合调用真实树过滤实现，验证祖先保留、重叠根和未加载范围。
final class WorkspaceDirectoryFilterTests: XCTestCase {
    func testMatchesIncludeAncestorsWithoutUnrelatedChildren() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let branch = root.appendingPathComponent("Branch", isDirectory: true)
        let match = branch.appendingPathComponent("Needle", isDirectory: true)
        let unrelated = branch.appendingPathComponent("Other", isDirectory: true)
        let children = [root: [entry(branch)], branch: [entry(match), entry(unrelated)]]
        XCTAssertEqual(WorkspaceDirectoryFilter.matches(query: "needle", roots: [root, branch], children: children),
                       Set([root, branch, match]))
        XCTAssertEqual(WorkspaceDirectoryFilter.matches(query: "branch", roots: [root], children: children),
                       Set([root, branch]))
        XCTAssertTrue(WorkspaceDirectoryFilter.matches(query: "unloaded", roots: [root], children: children).isEmpty)
        XCTAssertTrue(WorkspaceDirectoryFilter.matches(query: "", roots: [root], children: children).isEmpty)
    }

    private func entry(_ url: URL) -> FileEntry {
        FileEntry(url: url, name: url.lastPathComponent, isDirectory: true, isPackage: false,
                  isSymbolicLink: false, size: nil, modifiedAt: nil, typeIdentifier: nil)
    }
}
