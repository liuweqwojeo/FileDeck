import Foundation
import XCTest
@testable import FileWorkbench

final class FileSystemTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWorkbenchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEntriesUseNaturalSortingAndPlaceFoldersFirst() throws {
        try makeFile("file10.txt")
        try makeFile("file2.txt", contents: "hello")
        try makeFolder("folder10")
        try makeFolder("folder2")

        let entries = try FileSystem.entries(at: temporaryDirectory, showHidden: false)

        XCTAssertEqual(entries.map(\.name), ["folder2", "folder10", "file2.txt", "file10.txt"])
        let file = try XCTUnwrap(entries.first { $0.name == "file2.txt" })
        XCTAssertEqual(file.size, 5)
        XCTAssertNotNil(file.modifiedAt)
        XCTAssertEqual(file.id, file.url)
    }

    func testHiddenFilesAndFoldersFollowVisibilityOption() throws {
        try makeFile("visible.txt")
        try makeFile(".hidden.txt")
        try makeFolder(".hidden-folder")

        let visible = try FileSystem.entries(at: temporaryDirectory, showHidden: false)
        let all = try FileSystem.entries(at: temporaryDirectory, showHidden: true)

        XCTAssertEqual(visible.map(\.name), ["visible.txt"])
        XCTAssertEqual(Set(all.map(\.name)), ["visible.txt", ".hidden.txt", ".hidden-folder"])
        XCTAssertTrue(try FileSystem.folders(at: temporaryDirectory, showHidden: false).isEmpty)
        XCTAssertEqual(try FileSystem.folders(at: temporaryDirectory, showHidden: true).map(\.name), [".hidden-folder"])
    }

    func testApplicationPackagesAreFilesAndCannotBeExpanded() throws {
        let packageURL = try makeFolder("Example.app")
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try makeFolder("Documents")

        let entries = try FileSystem.entries(at: temporaryDirectory, showHidden: false)
        let package = try XCTUnwrap(entries.first { $0.name == "Example.app" })

        XCTAssertTrue(package.isDirectory)
        XCTAssertTrue(package.isPackage)
        XCTAssertFalse(package.isBrowsableDirectory)
        XCTAssertEqual(try FileSystem.folders(at: temporaryDirectory, showHidden: false).map(\.name), ["Documents"])
        XCTAssertThrowsError(try FileSystem.entries(at: packageURL, showHidden: false))
    }

    func testSymbolicLinksAreVisibleButNeverFollowed() throws {
        let folderURL = try makeFolder("actual-folder")
        let linkURL = temporaryDirectory.appendingPathComponent("folder-link")
        let cycleURL = temporaryDirectory.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: folderURL)
        try FileManager.default.createSymbolicLink(at: cycleURL, withDestinationURL: temporaryDirectory)

        let entries = try FileSystem.entries(at: temporaryDirectory, showHidden: false)
        let link = try XCTUnwrap(entries.first { $0.name == "folder-link" })
        let cycle = try XCTUnwrap(entries.first { $0.name == "cycle" })

        XCTAssertTrue(link.isSymbolicLink)
        XCTAssertFalse(link.isBrowsableDirectory)
        XCTAssertTrue(cycle.isSymbolicLink)
        XCTAssertFalse(cycle.isBrowsableDirectory)
        XCTAssertEqual(link.url.path, linkURL.path)
        XCTAssertEqual(try FileSystem.folders(at: temporaryDirectory, showHidden: false).map(\.name), ["actual-folder"])
        XCTAssertThrowsError(try FileSystem.entries(at: linkURL, showHidden: false))
    }

    func testMissingDirectoryPropagatesAnError() {
        let missingURL = temporaryDirectory.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try FileSystem.entries(at: missingURL, showHidden: false))
    }

    func testRegularFileCannotBeReadAsDirectory() throws {
        let fileURL = try makeFile("document.txt")
        XCTAssertThrowsError(try FileSystem.entries(at: fileURL, showHidden: false)) { error in
            guard case FileSystemError.notBrowsableDirectory = error else {
                return XCTFail("应返回不能浏览普通文件的明确错误，实际为：\(error)")
            }
        }
    }

    func testListingDoesNotRecursivelyReadNestedFiles() throws {
        let folderURL = try makeFolder("Documents")
        try Data("nested".utf8).write(to: folderURL.appendingPathComponent("nested.txt"))

        let entries = try FileSystem.entries(at: temporaryDirectory, showHidden: false)
        XCTAssertEqual(entries.map(\.name), ["Documents"])
        XCTAssertNil(entries.first?.size)
    }

    @discardableResult
    private func makeFolder(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
