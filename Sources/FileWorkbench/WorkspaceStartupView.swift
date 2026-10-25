import SwiftUI

/// 仅负责欢迎与恢复状态的呈现；操作继续使用 BrowserStore 的目录授权和恢复入口。
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
                    Text("FileDeck").font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在恢复工作区…").font(.system(size: 13))
                            .foregroundStyle(WorkspacePalette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    // 只在欢迎页采用双栏；窄窗压缩插画与间距，所有操作始终在一屏内。
                    let compact = geometry.size.width < 1020
                    let dense = geometry.size.height < (compact ? 800 : 640)
                    if compact {
                        let illustrationHeight = min(260, max(130, geometry.size.height * 0.23))
                        VStack(spacing: 0) {
                            WelcomeWorkspaceIllustration(compact: true)
                                .frame(height: illustrationHeight)
                            introduction(dense: dense)
                                .frame(maxWidth: 560)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(dense ? 24 : 32)
                        }
                        .background(.white)
                    } else {
                        HStack(spacing: 0) {
                            WelcomeWorkspaceIllustration(compact: false)
                                .frame(width: geometry.size.width * 0.44, height: geometry.size.height)
                            introduction(dense: dense)
                                .frame(maxWidth: 560)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(dense ? 28 : 40)
                                .background(.white)
                        }
                    }
                }
            }
        }
        .foregroundStyle(WorkspacePalette.primary)
        .background(WorkspacePalette.background)
        .tint(WorkspacePalette.accent)
    }

    private func introduction(dense: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceAppIcon(size: dense ? 44 : 72)
                .padding(.bottom, dense ? 12 : 20)
            Text("欢迎使用 FileDeck")
                .font(.system(size: dense ? 26 : 32, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("集中管理本地目录，快速浏览文件，即时预览内容。")
                .font(.system(size: dense ? 13 : 15))
                .foregroundStyle(WorkspacePalette.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, dense ? 8 : 12)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: dense ? 16 : 20) { features(dense: dense) }
                VStack(alignment: .leading, spacing: 12) { features(dense: dense) }
            }
            .padding(.vertical, dense ? 20 : 36)
            VStack(spacing: dense ? 4 : 10) {
                Button(action: hasPreviousWorkspace ? skipWelcome : chooseFolder) {
                    HStack(spacing: 10) {
                        Text(hasPreviousWorkspace ? "继续上次工作区" : "选择本地文件夹")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: dense ? 30 : 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button(hasPreviousWorkspace ? "选择其他本地文件夹" : "暂不添加，进入工作台",
                       action: hasPreviousWorkspace ? chooseFolder : skipWelcome)
                    .font(.system(size: 13))
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: dense ? 28 : 34)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            Spacer(minLength: dense ? 16 : 36)
            Label("所有文件仅在本机处理，不会上传到云端。", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(WorkspacePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func features(dense: Bool) -> some View {
        feature("目录管理", icon: "folder", detail: "常用目录，集中管理", dense: dense)
        feature("文件浏览", icon: "list.bullet.rectangle", detail: "清晰有序，快速查找", dense: dense)
        feature("实时预览", icon: "doc.text.magnifyingglass", detail: "双击文件，即刻查看", dense: dense)
    }

    // 三项沿用原来的能力说明语义，不伪装成会打开示例文件的按钮。
    private func feature(_ title: String, icon: String, detail: String, dense: Bool) -> some View {
        VStack(alignment: .leading, spacing: dense ? 6 : 10) {
            Image(systemName: icon)
                .font(.system(size: dense ? 21 : 24, weight: .regular))
                .foregroundStyle(WorkspacePalette.accent)
                .frame(width: dense ? 36 : 48, height: dense ? 36 : 48)
                .background(WorkspacePalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12))
                .foregroundStyle(WorkspacePalette.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 以原生矢量视图表达目录、列表与预览，随窗口清晰缩放，不依赖网络或新的图片资源。
/// 插画是示意而非真实文件列表，对辅助技术隐藏，避免产生无效的文件操作入口。
private struct WelcomeWorkspaceIllustration: View {
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "folder.badge.gearshape").font(.system(size: 28, weight: .light))
                            .foregroundStyle(WorkspacePalette.accent)
                        Text("让文件管理更简单").font(.system(size: 20, weight: .semibold))
                        Text("本地目录 · 即时预览").font(.system(size: 12))
                            .foregroundStyle(WorkspacePalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(WorkspacePalette.accent)
                        Image(systemName: "photo").foregroundStyle(.teal)
                    }.font(.system(size: 30, weight: .light))
                }
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    workspace
                    HStack(spacing: 12) {
                        preview(icon: "photo", title: "图片预览", color: .teal)
                        preview(icon: "doc.text", title: "文档预览", color: WorkspacePalette.accent)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("让文件管理更简单").font(.system(size: 25, weight: .semibold))
                        Text("本地目录 · 快速浏览 · 即时预览")
                            .font(.system(size: 13)).foregroundStyle(WorkspacePalette.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 440)
        .padding(compact ? 28 : 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.96, green: 0.98, blue: 1),
                                            Color(red: 0.87, green: 0.93, blue: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .accessibilityHidden(true)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red.opacity(0.65), .orange.opacity(0.65), .green.opacity(0.65)], id: \.self) { color in
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Spacer()
                Image(systemName: "sidebar.left").foregroundStyle(WorkspacePalette.secondary)
            }
            .font(.system(size: 11)).padding(14)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Label("文稿", systemImage: "folder").foregroundStyle(WorkspacePalette.accent)
                    Label("图片", systemImage: "photo")
                    Label("下载", systemImage: "arrow.down.circle")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(16)
                .frame(width: 104)
                .frame(maxHeight: .infinity)
                .background(WorkspacePalette.accent.opacity(0.035))
                Divider()
                VStack(spacing: 0) {
                    HStack { Text("我的文件").fontWeight(.semibold); Spacer(); Image(systemName: "magnifyingglass") }
                        .font(.system(size: 12)).padding(.bottom, 10)
                    fileRow("项目资料", icon: "folder.fill", color: WorkspacePalette.accent)
                    Divider()
                    fileRow("灵感与计划.md", icon: "doc.text.fill", color: WorkspacePalette.accent)
                    Divider()
                    fileRow("山间风景.jpg", icon: "photo.fill", color: .teal)
                    if !compact {
                        Divider()
                        fileRow("产品介绍.pdf", icon: "doc.richtext.fill", color: .orange)
                    }
                }.padding(16)
            }
            .frame(height: compact ? 170 : 228)
        }
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: WorkspacePalette.accent.opacity(0.07), radius: 16, y: 8)
    }

    private func fileRow(_ name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
                .frame(width: 24)
            Text(name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity)
    }

    private func preview(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 25, weight: .light)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 11, weight: .medium))
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.16)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.09)).frame(height: 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }
}
