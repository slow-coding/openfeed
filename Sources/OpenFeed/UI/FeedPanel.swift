import SwiftUI
import AppKit

enum FeedFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case repo = "仓库"
    case release = "版本"
    case story = "讨论"

    var id: String { rawValue }

    var kind: FeedKind? {
        switch self {
        case .all: return nil
        case .repo: return .repo
        case .release: return .release
        case .story: return .story
        }
    }
}

struct FeedPanel: View {
    @ObservedObject var store: FeedStore
    let onOpen: (FeedItem) -> Void
    let onRefresh: () -> Void
    let onMenu: (NSView?) -> Void

    @State private var filter: FeedFilter = .all
    @State private var dropTarget: String?
    @State private var menuAnchor = MenuAnchor()

    private var shownSections: [(day: Date, items: [FeedItem])] {
        store.sections().compactMap { section in
            guard let kind = filter.kind else { return section }
            let kept = section.items.filter { $0.kind == kind }
            return kept.isEmpty ? nil : (section.day, kept)
        }
    }

    private var totalShown: Int {
        shownSections.reduce(0) { $0 + $1.items.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Rectangle().fill(T.hairline).frame(height: 0.5)
            if store.items.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .frame(width: T.width, height: T.height)
    }

    // MARK: - 头

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                    .font(.system(size: 17, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: T.metaSize))
                    .foregroundStyle(store.phase.isRunning ? AnyShapeStyle(T.accent) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onRefresh) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.clear)
                        .frame(width: 26, height: 24)
                    if store.phase.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("现在拉一次")
            .disabled(store.phase.isRunning)

            Button {
                onMenu(menuAnchor.view)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("更多")
            .background(MenuAnchorView(anchor: menuAnchor).frame(width: 0, height: 0))
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusLine: String {
        if case .running(let text) = store.phase { return text }
        if case .failed(let text) = store.phase {
            return store.snapshot.items.isEmpty ? text : "上次没拉全：\(text)"
        }
        guard let last = store.snapshot.lastSuccessAt else { return "还没拉过 · 每天 09:00 自动" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let fresh = Calendar.current.isDateInToday(last) ? "\(clock.string(from: last)) 更新"
            : "\(formatter.string(from: last)) 更新"
        let new = store.unread(todayOnly: true)
        let leading = new > 0 ? "\(new) 条没看 · " : ""
        return "\(leading)\(fresh) · 每天 09:00 自动"
    }

    // MARK: - 筛选

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(FeedFilter.allCases) { option in
                chip(option)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.pad)
        .padding(.bottom, 11)
    }

    private func chip(_ option: FeedFilter) -> some View {
        let selected = filter == option
        let count = option.kind.map { kind in store.items.filter { $0.kind == kind }.count } ?? store.items.count
        return Button {
            filter = option
        } label: {
            HStack(spacing: 4) {
                Text(option.rawValue)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(selected ? T.accent.opacity(0.75) : Color.secondary.opacity(0.7))
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? T.accent : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? T.accent.opacity(0.13) : T.tile.opacity(0.7))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shownSections.isEmpty {
                    Text("这一类今天没有")
                        .font(.system(size: T.metaSize))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
                ForEach(shownSections, id: \.day) { section in
                    SectionHeader(day: section.day, count: section.items.count)
                    ForEach(section.items) { item in
                        FeedRow(
                            item: item,
                            isDropTarget: dropTarget == item.id,
                            onOpen: {
                                store.markVisited(item)
                                onOpen(item)
                            },
                            onMute: { store.mute(item) },
                            onHover: { inside in
                                if inside {
                                    store.setHover(item)
                                } else if store.hoveredID == item.id {
                                    store.setHover(nil)
                                }
                            }
                        )
                        .onDrop(of: [.text], delegate: RowDropDelegate(
                            target: item, day: section.day, store: store, dropTarget: $dropTarget
                        ))
                        Rectangle()
                            .fill(T.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, T.pad + T.icon + T.rowGap)
                    }
                }
                if !shownSections.isEmpty {
                    Text("最近 2 天 · 共 \(totalShown) 条")
                        .font(.system(size: T.metaSize))
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.quaternary)
            Text(store.phase.isRunning ? "正在拉第一批" : "还没拉过")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button(action: onRefresh) {
                Text("现在拉取")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(T.accent.opacity(0.14)))
                    .foregroundStyle(T.accent)
            }
            .buttonStyle(.plain)
            .disabled(store.phase.isRunning)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 让 ⋯ 菜单贴着按钮弹：SwiftUI 的 Menu 在这个面板里会被裁掉，所以用 AppKit 锚点。
final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
