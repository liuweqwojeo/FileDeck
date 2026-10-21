import AppKit
import SwiftUI

/// 属性独立于预览结果：格式不受支持时仍显示文件信息，磁盘读取在后台完成。
struct FileMetadataView: View {
    let entry: FileEntry
    var revision: UUID = UUID()
    @State private var snapshot: MetadataSnapshot?
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2).textSelection(.enabled)
                Text(entry.typeLabel)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 0) {
                property("文件类型", entry.typeLabel)
                property("文件大小", formattedSize)
                property("创建时间", dateText(snapshot?.createdAt))
                property("修改时间", dateText(snapshot?.modifiedAt ?? entry.modifiedAt))
                property("文件权限", snapshot?.permissions ?? "—")
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("文件路径").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url.path, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain).help("复制文件路径")
                    .accessibilityLabel("复制文件路径")
                }
                Text(entry.url.path)
                    .textSelection(.enabled)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 7))
            }.font(.system(size: 12))
            if unavailable {
                Label("部分属性暂时无法读取", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task(id: MetadataIdentity(url: entry.url, revision: revision)) {
            snapshot = nil
            unavailable = false
            let url = entry.url
            let result = await Task.detached(priority: .utility) { MetadataSnapshot.read(url) }.value
            guard !Task.isCancelled else { return }
            snapshot = result
            unavailable = result == nil
        }
    }

    private var formattedSize: String {
        // 目录的 inode 大小不是内容容量，不能作为文件夹总容量显示。
        guard !entry.isDirectory, let size = snapshot?.size ?? entry.size else { return "—" }
        return size == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) ?? "—"
    }

    private func property(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .frame(minHeight: 30)
    }
}

private struct MetadataIdentity: Hashable {
    let url: URL
    let revision: UUID
}

private struct MetadataSnapshot: Sendable {
    let createdAt: Date?
    let modifiedAt: Date?
    let size: Int64?
    let permissions: String

    static func read(_ url: URL) -> MetadataSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        let permissions: String
        switch (readable, writable) {
        case (true, true): permissions = "读取与写入"
        case (true, false): permissions = "只读"
        case (false, true): permissions = "仅写入"
        case (false, false): permissions = "无读取与写入权限"
        }
        return MetadataSnapshot(createdAt: attributes[.creationDate] as? Date,
                                modifiedAt: attributes[.modificationDate] as? Date,
                                size: (attributes[.size] as? NSNumber)?.int64Value,
                                permissions: permissions)
    }
}
