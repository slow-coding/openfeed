import AppKit
import SwiftUI

/// 预览卡挂在主面板左边（菜单栏在最右边，往左才放得下）。
/// 它不跟鼠标走：停在哪个条目就一直显示，直到你点开它、点外面、或者换到另一条。
/// 图 / 一句话是异步到的，所以开出来的头三秒按内容把高度收一次。
@MainActor
final class PreviewController {
    static let size = NSSize(width: PreviewCard.width, height: 470)
    static let maxHeight: CGFloat = 620

    private var panel: NSPanel?
    private var host: NSHostingView<PreviewCard>?
    private var sizeTimer: Timer?
    private var anchorWindow: NSWindow?
    private var model: PreviewModel?
    private var currentItem: FeedItem?
    private var onOpen: ((FeedItem) -> Void)?
    private var onRate: ((FeedItem, Int) -> Void)?

    var isShown: Bool { panel?.isVisible ?? false }

    var frameDescription: String {
        guard let panel, panel.isVisible else { return "hidden" }
        let frame = panel.frame
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    func show(item: FeedItem, beside window: NSWindow,
              onOpen: @escaping (FeedItem) -> Void,
              onRate: @escaping (FeedItem, Int) -> Void = { _, _ in }) {
        anchorWindow = window
        self.onOpen = onOpen
        self.onRate = onRate

        let wasVisible = panel?.isVisible == true
        let sameItem = currentItem?.id == item.id && wasVisible
        currentItem = item
        if sameItem { startSizing(); return }

        let open: () -> Void = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.onOpen?(item)
        }
        let rate: (Int) -> Void = { [weak self] stars in
            guard let self, let item = self.currentItem else { return }
            self.onRate?(item, stars)
        }

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
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
            self.panel = panel

            let model = PreviewModel(item: item)
            let host = NSHostingView(rootView: PreviewCard(model: model, onOpen: open, onRate: rate))
            host.frame = NSRect(origin: .zero, size: Self.size)
            panel.contentView = host
            self.host = host
            self.model = model
        } else if let model {
            // 只改这一条：卡片自己淡过去，不重建整棵树
            model.item = item
        }

        if panel != nil {
            var frame = panel!.frame
            frame.size.height = fittedHeight()
            panel?.setFrame(frame, display: false)
        }
        position()
        panel?.orderFrontRegardless()
        if !wasVisible {
            // 从没显示到显示才淡入；已经在屏幕上就是直接换内容，不闪一下
            panel?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel?.animator().alphaValue = 1
            }
        } else {
            panel?.alphaValue = 1
        }
        startSizing()
    }

    func hide() {
        sizeTimer?.invalidate(); sizeTimer = nil
        currentItem = nil
        panel?.orderOut(nil)
    }

    /// 只做一件事：内容到了把高度收好。不做「鼠标走了就收」——那是他明确不要的。
    private func startSizing() {
        sizeTimer?.invalidate()
        var ticks = 0
        sizeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                ticks += 1
                self?.resizeIfNeeded()
                if ticks > 24 { self?.sizeTimer?.invalidate(); self?.sizeTimer = nil }
            }
        }
    }

    private func resizeIfNeeded() {
        guard let panel, panel.isVisible else { return }
        let target = fittedHeight()
        guard abs(panel.frame.height - target) > 2 else { return }
        let top = panel.frame.maxY
        var frame = panel.frame
        frame.size.height = target
        frame.origin.y = max(8, top - target)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func fittedHeight() -> CGFloat {
        guard let host else { return Self.size.height }
        host.layoutSubtreeIfNeeded()
        return min(Self.maxHeight, max(300, host.fittingSize.height))
    }

    private func position() {
        guard let panel, let screen = anchorWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // 贴着面板左边，中间不留缝：鼠标从列表挪过来不会「掉出去」
        var x = (anchorWindow?.frame.minX ?? visible.maxX) - Self.size.width - 4
        if x < visible.minX + 8 {
            x = (anchorWindow?.frame.maxX ?? visible.minX) + 4
        }
        let mouseY = NSEvent.mouseLocation.y
        var y = mouseY - 28
        let height = panel.frame.height
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: height), display: true)
    }
}
