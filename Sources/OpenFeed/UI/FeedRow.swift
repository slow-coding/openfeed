import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FeedRow: View {
    let item: FeedItem
    let isDropTarget: Bool
    let onOpen: () -> Void
    let onMute: () -> Void
    let onHover: (Bool) -> Void
    let onRate: (Int) -> Void
    /// 自检用：不真的悬停也能看到悬停时的样子
    var forceHover: Bool = false

    @State private var hovering = false
    @State private var copied = false
    @State private var hoveringRating = false
    @State private var hoverStar: Int?

    private var shown: Bool { hovering || forceHover }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: T.rowGap) {
                RowIcon(item: item)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: T.titleSize, weight: .semibold))
                            .foregroundStyle(item.visitedAt == nil ? Color.primary : Color.primary.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        topRight
                    }
                    .frame(height: T.icon, alignment: .center)

                    if let summary = item.coreLine ?? (item.summary.isEmpty ? nil : item.summary) {
                        Text(summary)
                            .font(.system(size: T.summarySize))
                            .foregroundStyle(.secondary)
                            .lineLimit(item.isRepo ? 2 : 1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    meta
                }
                .frame(width: T.textColumn, alignment: .leading)
            }
            .padding(.horizontal, T.pad)
            .padding(.vertical, T.rowTop)
            .frame(width: T.width, alignment: .leading)
            .background(shown ? T.rowHover : Color.clear)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(T.accent)
                    .frame(height: isDropTarget ? 2 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                copyButton
                    .padding(.trailing, T.pad - 6)
                    .padding(.bottom, T.rowTop - 4)
                    .opacity(shown || copied ? 1 : 0)
                    .allowsHitTesting(shown || copied)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .onDrag {
            NSItemProvider(object: item.id as NSString)
        }
        .contextMenu {
            Button("在浏览器打开") { onOpen() }
            Button("复制链接与一句话") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.copyText, forType: .string)
            }
            Divider()
            Menu("评分") {
                ForEach(1...5, id: \.self) { n in
                    Button("\(String(repeating: "★", count: n))\(item.rating == n ? "（当前）" : "")") {
                        onRate(n)
                    }
                }
                if item.rating > 0 {
                    Divider()
                    Button("清除评分") { onRate(0) }
                }
            }
            if item.isRepo {
                Divider()
                Button("不再显示 \(item.title)") { onMute() }
            }
        }
    }

    /// 右上角那一格：平时是 GitHub 星数，鼠标一停上去就换成 5 颗可点的星。
    /// 宽度写死 64，换成星星的时候标题不会跟着折一下。
    private var topRight: some View {
        ZStack(alignment: .trailing) {
            if hoveringRating || forceHover {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            onRate(n == item.rating ? 0 : n)
                        } label: {
                            Image(systemName: n <= item.rating ? "star.fill" : "star")
                                .font(.system(size: 10.5))
                                .foregroundStyle(color(for: n))
                                .frame(width: 12, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hoverStar = n } else if hoverStar == n { hoverStar = nil }
                        }
                    }
                }
            } else {
                trailing
            }
        }
        .frame(width: 64, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveringRating = inside
        }
        .help(hoveringRating ? "点第 N 颗打 N 星，再点一次取消" : "鼠标放上去可以打分")
    }

    private func color(for n: Int) -> Color {
        if n <= item.rating { return T.accent }
        if let hoverStar, n <= hoverStar { return T.accent.opacity(0.55) }
        return Color.secondary.opacity(0.55)
    }

    /// 列表行右下角的复制键：跟代码块上那颗一样，停上去才出来。
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.copyText, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(copied ? T.accent : Color.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制" : "复制链接与一句话")
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.kind {
        case .repo:
            if let stars = item.stars {
                Label(stars.starText, systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: T.metaSize, weight: .medium))
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        case .story:
            if let points = item.stars {
                Text("\(points) 分")
                    .font(.system(size: T.metaSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        case .release:
            Text(item.createdAt.agoText)
                .font(.system(size: T.metaSize))
                .foregroundStyle(.tertiary)
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if item.isExploration {
                Text("探索")
                    .font(.system(size: T.metaSize, weight: .medium))
                    .foregroundStyle(T.accent)
                separator
            }
            Circle()
                .fill(T.lane(item.lane))
                .frame(width: 4, height: 4)
            Text(item.lane)
                .foregroundStyle(.secondary.opacity(0.85))
            separator
            Text(item.subtitle)
                .foregroundStyle(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            if let language = item.language, !language.isEmpty {
                separator
                Text(language).foregroundStyle(.secondary.opacity(0.85))
            }
            if item.kind == .repo, let delta = item.starsDelta, delta > 0 {
                separator
                Text("↑\(delta.starText)")
                    .foregroundStyle(T.lane(item.lane).opacity(0.9))
            }
            if item.rating > 0 {
                separator
                Text("\(String(repeating: "★", count: item.rating))")
                    .foregroundStyle(T.accent.opacity(0.9))
                    .font(.system(size: T.metaSize - 0.5))
            }
            if item.visitedAt == nil, item.isNewToday {
                separator
                Text("价值 \(Int(item.value.rounded()))")
                    .foregroundStyle(.quaternary)
                    .monospacedDigit()
            }
            separator
            Text(item.createdAt.agoText)
                .foregroundStyle(.secondary.opacity(0.85))
                .fixedSize()
        }
        .font(.system(size: T.metaSize))
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }
}

struct SectionHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.dayHeader)
                .font(.system(size: T.sectionSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: T.sectionSize))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 16)
        .padding(.bottom, 2)
    }
}

/// 拖到哪一行，就在那一行上面画一条线；松手才真的换位置。
struct RowDropDelegate: DropDelegate {
    let target: FeedItem
    let day: Date
    let store: FeedStore
    @Binding var dropTarget: String?

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        dropTarget = target.id
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target.id { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let id = value as? String, id != target.id else { return }
            Task { @MainActor in
                store.move(id, before: target.id, day: day)
            }
        }
        return true
    }
}
