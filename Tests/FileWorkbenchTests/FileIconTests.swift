import AppKit
import XCTest
@testable import FileWorkbench

/// 验证目录/应用/链接边界和真实系统符号可用性，不把视觉分类当作编辑能力。
@MainActor
final class FileIconTests: XCTestCase {
    func testDirectoryAndPackageTakePriorityOverDocumentSuffix() {
        let folder = WorkspaceFileIconDescriptor(url: URL(fileURLWithPath: "/not-created/report.pdf"), isDirectory: true)
        XCTAssertEqual(folder.kind, .folder)
        let package = WorkspaceFileIconDescriptor(url: URL(fileURLWithPath: "/not-created/Preview.app"), isDirectory: true, isPackage: true)
        XCTAssertEqual(package.kind, .system)
    }
    func testSnapshotLinkBadgeDoesNotFollowMissingTarget() {
        let icon = WorkspaceFileIconDescriptor(url: URL(fileURLWithPath: "/not-created/broken.json"), isSymbolicLink: true)
        XCTAssertTrue(icon.isSymbolicLink)
        XCTAssertEqual(icon.kind, .structuredText)
    }
    func testLegacyOfficeAppearanceDoesNotEnableEditing() {
        let url = URL(fileURLWithPath: "/not-created/legacy.doc")
        XCTAssertEqual(WorkspaceFileIconDescriptor(url: url).kind, .word)
        XCTAssertEqual(FileCapabilityRegistry().capabilities(for: url).kind, .other)
        XCTAssertFalse(FileCapabilityRegistry().capabilities(for: url).operations.contains(.edit))
    }
    func testSymbolsExistInSystemFramework() {
        for kind in WorkspaceFileIconDescriptor.Kind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), "Missing SF Symbol: \(kind.symbol)")
        }
    }
}
