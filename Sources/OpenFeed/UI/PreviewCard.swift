import SwiftUI
import AppKit

/// 悬停时弹在面板左边的那张卡：先给图，再给字。
/// 图是主图（README 里第一张产品图），拿不到就退到 GitHub 的分享卡，再不行退头像。
struct PreviewCard: View {
    let item: FeedItem
    let onOpen: () -> Void
    var onRate: (Int) -> Void = { _ in }

    @State private var image: NSImage?
    @State private var tried = false
    @State private var coreLine: String?
    @State private var rating: Int
    @State private var hoverStar: Int?

    init(item: FeedItem, onOpen: @escaping () -> Void, onRate: @escaping (Int) -> Void = { _ in }) {
        self.item = item
        self.onOpen = onOpen
        self.onRate = onRate
        _rating = State(initialValue: item.rating)
    }

    static let width: CGFloat = 380
    static let imageHeight: CGFloat = 196

    var body: some View {
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
        // 每条一份自己的状态：不然换到下一条时，image / coreLine 会沿用上一条，
        // 看起来就是「图重复了」或者「没更新」。
        .id(item.id)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(T.hairline, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 整卡可点开；页脚那 5 颗星是自己的手势，会先接住点击，不会误开浏览器
        .onTapGesture { onOpen() }
        .task(id: item.id) {
            image = nil
            tried = false
            // 分享卡通常已经缓存过，先顶上，别让那块空着等 README 解析
            if let url = item.imageURL, let data = ImageStore.shared.cached("og|\(url.absoluteString)") {
                image = NSImage(data: data)
            }
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

    /// 打分放在页脚右侧：不占高度，也不会跟「打开」抢点击。
    private var stars: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    let next = (n == rating) ? 0 : n
                    rating = next
                    onRate(next)
                } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .font(.system(size: 12.5))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(color(for: n))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoverStar = n } else if hoverStar == n { hoverStar = nil }
                }
                .help(n == rating ? "点一下取消" : "打 \(n) 星")
            }
        }
        .animation(.easeOut(duration: 0.08), value: rating)
    }

    private func color(for n: Int) -> Color {
        if n <= rating { return T.star }
        if let hoverStar, n <= hoverStar { return T.star.opacity(0.55) }
        return Color.secondary.opacity(0.4)
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
            Spacer(minLength: 8)
            stars
        }
    }
}
