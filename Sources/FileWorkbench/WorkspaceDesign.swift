import SwiftUI

/// 启动页和工作区共用的浅色系统配色，避免各类空状态出现不同的视觉层级。
enum WorkspacePalette {
    static let background = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let sidebar = background
    static let preview = Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
    static let primary = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)
    static let tertiary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let accent = Color(red: 0, green: 122 / 255, blue: 1)
    static let separator = Color.black.opacity(0.09)
    static let emptyIcon = Color(red: 174 / 255, green: 188 / 255, blue: 204 / 255)
}

struct WorkspaceEmptyState<Actions: View>: View {
    let title: String
    let icon: String
    let detail: String
    var iconColor: Color = WorkspacePalette.emptyIcon
    var badge: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(iconColor)
                .frame(height: 76)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 24, weight: .medium))
                            .foregroundStyle(WorkspacePalette.secondary)
                            .padding(5).background(WorkspacePalette.background, in: Circle())
                            .offset(x: 10, y: 2)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 17)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WorkspacePalette.primary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(WorkspacePalette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.top, 9)
            actions().padding(.top, 22)
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 启动页复用应用包图标，避免与 Finder、Dock 显示不同的品牌标识。
struct WorkspaceAppIcon: View {
    var size: CGFloat = 80
    private static let image = Bundle.main.url(forResource: "FileDeck", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
