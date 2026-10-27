import AppKit
import SwiftUI

/// 预览卡挂在主面板左边（菜单栏在最右边，往左才放得下），高度跟着鼠标走。
/// 鼠标离开两个窗口 300ms 后收起；进入卡片就不收，这样才能点。
@MainActor
final class PreviewController {
    static let size = NSSize(width: PreviewCard.width, height: 470)
    static let maxHeight: CGFloat = 620

    private var panel: NSPanel?
    private var host: NSHostingView<PreviewCard>?
    private var timer: Timer?
    private var hideAt: Date?
    private var anchorWindow: NSWindow?
    private var currentID: String?
    private var onOpen: ((FeedItem) -> Void)?

    var isShown: Bool { panel?.isVisible ?? false }

    var frameDescription: String {
        guard let panel, panel.isVisible else { return "hidden" }
        let frame = panel.frame
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    func show(item: FeedItem, beside window: NSWindow, onOpen: @escaping (FeedItem) -> Void) {
        if currentID == item.id, panel?.isVisible == true { return }
        currentID = item.id
        anchorWindow = window
        self.onOpen = onOpen

        let card = PreviewCard(item: item) { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onOpen?(item)
        }
        currentItem = item

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            self.panel = panel

            let host = NSHostingView(rootView: card)
            host.frame = NSRect(origin: .zero, size: Self.size)
            panel.contentView = host
            self.host = host
        } else {
            host?.rootView = card
        }

        // 高度跟着卡片内容走，别在底下留一截空白
        if panel != nil {
            var frame = panel!.frame
            frame.size.height = fittedHeight()
            panel?.setFrame(frame, display: false)
        }
        position(item: item)
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel?.animator().alphaValue = 1
        }
        startTracking()
    }

    private var currentItem: FeedItem?

    func hide() {
        timer?.invalidate(); timer = nil
        hideAt = nil
        currentID = nil
        currentItem = nil
        panel?.orderOut(nil)
    }

    private func fittedHeight() -> CGFloat {
        guard let host else { return Self.size.height }
        host.layoutSubtreeIfNeeded()
        return min(Self.maxHeight, max(300, host.fittingSize.height))
    }

    private func position(item: FeedItem) {
        guard let panel, let screen = anchorWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = (anchorWindow?.frame.minX ?? visible.maxX) - Self.size.width - 10
        if x < visible.minX + 8 {
            x = (anchorWindow?.frame.maxX ?? visible.minX) + 10
        }
        let mouseY = NSEvent.mouseLocation.y
        var y = mouseY - 28
        let height = panel.frame.height
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: height), display: true)
    }

    private func startTracking() {
        timer?.invalidate()
        hideAt = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let panel, panel.isVisible else { hide(); return }
        // 图和一句话是异步来的，来了窗口要跟着长；松手时定死就会把页脚裁掉。
        let target = fittedHeight()
        if abs(panel.frame.height - target) > 2 {
            let top = panel.frame.maxY
            var frame = panel.frame
            frame.size.height = target
            frame.origin.y = max(8, top - target)
            panel.setFrame(frame, display: true, animate: false)
        }
        let mouse = NSEvent.mouseLocation
        let insidePanel = panel.frame.contains(mouse)
        let insidePopover = anchorWindow?.frame.contains(mouse) ?? false
        if insidePanel || insidePopover {
            hideAt = nil
            return
        }
        if let hideAt {
            if Date() >= hideAt { hide() }
        } else {
            hideAt = Date().addingTimeInterval(0.3)
        }
    }
}
