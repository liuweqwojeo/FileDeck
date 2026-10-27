import AppKit
import SwiftUI

/// 两侧栏分别保存宽度，中栏占用剩余空间；隐藏预览不会覆盖用户之前设定的宽度。
struct WorkspaceSplitView<Sidebar: View, Content: View, Preview: View>: View {
    let showPreview: Bool
    var expandPreview = false
    var showSidebar = true
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let preview: () -> Preview
    @AppStorage("FileWorkbench.sidebarWidth") private var savedSidebarWidth = 260.0
    @AppStorage("FileWorkbench.previewWidth") private var savedPreviewWidth = 520.0
    @State private var sidebarDragOrigin: CGFloat?
    @State private var previewDragOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let widths = columnWidths(available: geometry.size.width)
            HStack(spacing: 0) {
                sidebar().frame(width: widths.sidebar).clipped()
                    .allowsHitTesting(showSidebar).accessibilityHidden(!showSidebar).disabled(!showSidebar)
                if showSidebar {
                    divider(label: "调整导航栏宽度", change: { translation in
                        if sidebarDragOrigin == nil { sidebarDragOrigin = widths.sidebar }
                        savedSidebarWidth = boundedSidebar((sidebarDragOrigin ?? widths.sidebar) + translation,
                                                           available: geometry.size.width)
                    }, end: { sidebarDragOrigin = nil }, adjust: { direction in
                        savedSidebarWidth = boundedSidebar(widths.sidebar + direction, available: geometry.size.width)
                    })
                }
                content().frame(width: expandPreview ? 0 : max(0, geometry.size.width - widths.sidebar - widths.preview - (showPreview ? 1 : 0) - (showSidebar ? 1 : 0)))
                    .clipped().allowsHitTesting(!expandPreview).accessibilityHidden(expandPreview)
                if showPreview && !expandPreview {
                    divider(label: "调整预览栏宽度", change: { translation in
                        if previewDragOrigin == nil { previewDragOrigin = widths.preview }
                        savedPreviewWidth = boundedPreview((previewDragOrigin ?? widths.preview) - translation,
                                                           available: geometry.size.width, sidebar: widths.sidebar)
                    }, end: { previewDragOrigin = nil }, adjust: { direction in
                        savedPreviewWidth = boundedPreview(widths.preview + direction,
                                                           available: geometry.size.width, sidebar: widths.sidebar)
                    })
                }
                // 隐藏时宽度归零，但原生编辑器仍挂载，继续持有未保存内容。
                preview().frame(width: widths.preview).clipped()
                    .allowsHitTesting(showPreview).accessibilityHidden(!showPreview)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func columnWidths(available: CGFloat) -> (sidebar: CGFloat, preview: CGFloat) {
        let sidebar = showSidebar ? boundedSidebar(savedSidebarWidth, available: available) : 0
        return (sidebar, showPreview ? (expandPreview ? available - sidebar - 1 : boundedPreview(savedPreviewWidth, available: available, sidebar: sidebar)) : 0)
    }

    private func boundedSidebar(_ width: CGFloat, available: CGFloat) -> CGFloat {
        // 最小窗口下仍为文件列表留出 360 pt，预览留出 320 pt；只约束显示，不改写存储宽度。
        let maximum = max(220, min(340, available - 360 - (showPreview && !expandPreview ? 322 : 1)))
        return min(max(width.isFinite ? width : 260, 220), maximum)
    }

    private func boundedPreview(_ width: CGFloat, available: CGFloat, sidebar: CGFloat) -> CGFloat {
        let maximum = max(320, available - sidebar - 362)
        return min(max(width.isFinite ? width : 520, 320), maximum)
    }

    private func divider(label: String, change: @escaping (CGFloat) -> Void,
                         end: @escaping () -> Void, adjust: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(WorkspacePalette.separator)
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { change($0.translation.width) }
                        .onEnded { _ in end() })
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(20)
                case .decrement: adjust(-20)
                @unknown default: break
                }
            }
    }
}
