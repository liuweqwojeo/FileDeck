import SwiftUI

/// 普通启动停留在欢迎页，只有用户继续后才恢复目录；恢复页只反馈真实恢复过程。
struct WorkspaceStartupView: View {
    let isRestoring: Bool
    var hasPreviousWorkspace = false
    let chooseFolder: () -> Void
    let skipWelcome: () -> Void

    var body: some View {
        Group {
            if isRestoring {
                VStack(spacing: 20) {
                    WorkspaceAppIcon(size: 64)
                    Text("FileDeck")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(WorkspacePalette.primary)
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在恢复工作区…")
                            .font(.system(size: 13))
                            .foregroundStyle(WorkspacePalette.secondary)
                    }
                }
            } else {
                welcome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.background)
        .tint(WorkspacePalette.accent)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            WorkspaceAppIcon()
                .padding(.bottom, 28)
            Text("欢迎使用 FileDeck")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WorkspacePalette.primary)
                .multilineTextAlignment(.center)
            Text("集中管理本地目录，快速浏览文件，即时预览内容。")
                .font(.system(size: 14))
                .foregroundStyle(WorkspacePalette.secondary)
                .padding(.top, 12)
            HStack(alignment: .top, spacing: 0) {
                feature("目录管理", icon: "folder.badge.plus", detail: "常用目录，集中管理")
                feature("文件浏览", icon: "list.bullet.rectangle", detail: "清晰有序，快速查找")
                feature("实时预览", icon: "doc.text.magnifyingglass", detail: "双击文件，即刻查看")
            }
            .padding(.top, 46)
            .padding(.bottom, 44)
            Button(action: hasPreviousWorkspace ? skipWelcome : chooseFolder) {
                Text(hasPreviousWorkspace ? "继续上次工作区" : "选择本地文件夹")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 220, height: 44)
                    .foregroundStyle(.white)
                    .background(WorkspacePalette.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Button(hasPreviousWorkspace ? "选择其他本地文件夹" : "暂不添加，进入工作台",
                   action: hasPreviousWorkspace ? chooseFolder : skipWelcome)
                .font(.system(size: 13))
                .foregroundStyle(WorkspacePalette.secondary)
                .buttonStyle(.plain)
                .padding(.vertical, 17)
            Label("所有文件仅在本机处理，不会上传到云端。", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(WorkspacePalette.tertiary)
                .padding(.top, 27)
        }
        .frame(width: 520)
        .padding(30)
    }

    private func feature(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(WorkspacePalette.accent)
                .frame(height: 34)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WorkspacePalette.primary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(WorkspacePalette.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
