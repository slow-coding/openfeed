import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FeedRow: View {
    let item: FeedItem
    let isDropTarget: Bool
    let onOpen: () -> Void
    let onMute: () -> Void
    let onHover: (Bool) -> Void
    /// 自检用：不真的悬停也能看到悬停时的样子
    var forceHover: Bool = false

    @State private var hovering = false
    @State private var copied = false

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
                        trailing
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
            if item.isRepo {
                Divider()
                Button("不再显示 \(item.title)") { onMute() }
            }
        }
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
