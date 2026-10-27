import SwiftUI
import AppKit

struct FeedRow: View {
    let item: FeedItem
    let onOpen: () -> Void
    let onMute: () -> Void

    @State private var hovering = false

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
                    if !item.summary.isEmpty {
                        Text(item.summary)
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
            .background(hovering ? T.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在浏览器打开") { onOpen() }
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            if item.isRepo {
                Divider()
                Button("不再显示 \(item.title)") { onMute() }
            }
        }
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
