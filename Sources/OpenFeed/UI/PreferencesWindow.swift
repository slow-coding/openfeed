import AppKit
import SwiftUI

/// 设置窗：一屏能直接改的字，保存就重排。
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let store: FeedStore

    init(store: FeedStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L.t("当下偏好", "Preferences")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PreferencesView(
            text: PreferencesDoc.load(),
            onSave: { [weak self] text in
                guard let self else { return }
                self.store.applyPreferencesDoc(text)
                self.close()
            }
        ))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @State var text: String
    let onSave: (String) -> Void
    @State private var dirty = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .frame(minHeight: 460)
                    .onChange(of: text) { _ in dirty = true }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))

            Divider().overlay(T.hairline)

            HStack(spacing: 10) {
                Button {
                    text = PreferencesDoc.fallback
                    dirty = true
                } label: {
                    Text(L.t("恢复默认", "Reset to default"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(T.tile))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Text(L.t("提到的线会加权重，保存后立刻重排", "Mentioned lanes gain weight; saving re-ranks right away"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    if dirty { onSave(text) } else { NSApp.keyWindow?.performClose(nil) }
                } label: {
                    Text(dirty ? L.t("保存并重排", "Save & re-rank") : "关闭")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(dirty ? T.accent : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(dirty ? T.accent.opacity(0.16) : T.tile))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}
