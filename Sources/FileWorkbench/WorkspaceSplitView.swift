import AppKit
import SwiftUI

/// 浏览区只保留侧栏与内容；预览由原生模态层管理，拖动结束后才持久化宽度。
struct WorkspaceSplitView<Sidebar: View, Content: View>: View {
    var showSidebar = true
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @AppStorage("FileWorkbench.sidebarWidth") private var savedSidebarWidth = 260.0
    @State private var sidebarDragOrigin: CGFloat?
    @State private var draggedSidebarWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = showSidebar ? boundedSidebar(draggedSidebarWidth ?? savedSidebarWidth, available: geometry.size.width) : 0
            HStack(spacing: 0) {
                sidebar().frame(width: sidebarWidth).clipped()
                    .allowsHitTesting(showSidebar).accessibilityHidden(!showSidebar).disabled(!showSidebar)
                if showSidebar {
                    divider(label: "调整导航栏宽度", change: { translation in
                        if sidebarDragOrigin == nil { sidebarDragOrigin = sidebarWidth }
                        // 高频拖动只更新瞬时状态，避免每个鼠标事件都提交 AppStorage。
                        draggedSidebarWidth = boundedSidebar((sidebarDragOrigin ?? sidebarWidth) + translation,
                                                             available: geometry.size.width)
                    }, end: {
                        if let draggedSidebarWidth { savedSidebarWidth = draggedSidebarWidth }
                        draggedSidebarWidth = nil; sidebarDragOrigin = nil
                    }, adjust: { direction in
                        savedSidebarWidth = boundedSidebar(sidebarWidth + direction, available: geometry.size.width)
                    })
                }
                content().frame(width: max(0, geometry.size.width - sidebarWidth - (showSidebar ? 1 : 0)))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func boundedSidebar(_ width: CGFloat, available: CGFloat) -> CGFloat {
        // 最小窗口下仍为文件列表留出 360 pt；显示约束不覆盖用户保存的宽度。
        let maximum = max(220, min(340, available - 361))
        return min(max(width.isFinite ? width : 260, 220), maximum)
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
