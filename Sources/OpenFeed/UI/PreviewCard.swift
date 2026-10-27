import SwiftUI
import AppKit

/// 悬停时弹在面板左边的那张卡：先给图，再给字。
/// 图是主图（README 里第一张产品图），拿不到就退到 GitHub 的分享卡，再不行退头像。
struct PreviewCard: View {
    let item: FeedItem
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var tried = false
    @State private var coreLine: String?
    @State private var copied = false

    static let width: CGFloat = 380
    static let imageHeight: CGFloat = 196

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 9) {
                    header
                    if let coreLine {
                        Text(coreLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(coreLine == nil ? 5 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !topics.isEmpty { tags }
                    Divider().overlay(T.hairline)
                    footer
                }
                .padding(14)
            }
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(T.hairline, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            coreLine = item.coreLine ?? CoreValue.cached(item.id)
            async let picture = KeyImage.display(item)
            if let line = await CoreValue.line(for: item) {
                coreLine = line
                NotificationCenter.default.post(name: .openFeedCoreLine, object: nil,
                                                userInfo: ["id": item.id, "line": line])
            }
            if let data = await picture { image = NSImage(data: data) }
            tried = true
        }
    }

    private var hero: some View {
        ZStack {
            Rectangle().fill(T.tile)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.imageHeight)
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: tried ? "photo" : "photo.on.rectangle.angled")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(tried ? "这个仓库没有可用的图" : "找图…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(width: Self.width, height: Self.imageHeight)
        .clipped()
        .overlay(alignment: .topTrailing) { copyButton.padding(10) }
    }

    /// 压在图上，所以用固定的深底白字：图是任意颜色，磨砂在深色图上几乎看不见。
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.copyText, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Group {
                if copied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text("已复制").font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
            }
            .foregroundStyle(.white.opacity(0.95))
            .background(
                Capsule().fill(Color.black.opacity(copied ? 0.62 : 0.45))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("复制链接与一句话")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let stars = item.stars, item.kind != .story {
                    Label(stars.starText, systemImage: "star.fill")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if item.kind == .story, let points = item.stars {
                    Text("\(points) 分")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 5) {
                Text(item.repoSlug ?? item.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let language = item.language {
                    Text("·")
                    Text(language)
                }
                Text("·")
                Text(item.createdAt.agoText)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }

    private var topics: [String] {
        var list: [String] = []
        if item.isExploration { list.append("探索") }
        list.append(item.lane)
        return list
    }

    private var tags: some View {
        HStack(spacing: 5) {
            ForEach(topics, id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 10))
                    .foregroundStyle(topic == "探索" ? T.accent : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(topic == "探索" ? T.accent.opacity(0.12) : T.tile.opacity(0.8)))
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("价值 \(Int(item.value.rounded()))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !item.reasons.isEmpty {
                Text("·").foregroundStyle(.quaternary)
                Text(item.reasons.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
