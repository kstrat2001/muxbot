import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A drafted bug: what you described, measured page facts, and two ways
/// forward: file it on GitHub (prefilled, screenshot on the clipboard) or
/// send it straight to the Coder crew.
struct BugCardView: View {
    let message: ChatMessage

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(PreviewController.self) private var preview

    private var draft: BugDraft? {
        try? JSONDecoder().decode(BugDraft.self, from: Data(message.content.utf8))
    }

    var body: some View {
        if let draft {
            CardView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Bug: \(draft.title)", systemImage: "ladybug").font(AppFont.headline())
                    Text("\(draft.page)\(draft.viewport.map { " · \($0)px wide" } ?? "")")
                        .font(AppFont.caption()).foregroundStyle(.secondary)
                    ForEach(draft.facts, id: \.self) { Text($0).font(AppFont.footnote()) }
                    HStack {
                        Button("File on GitHub", systemImage: "arrow.up.forward.square") { file(draft) }
                            .buttonStyle(.bordered)
                            .disabled(draft.issueURL == nil)
                        Spacer()
                        Button("Fix it now", systemImage: "hammer") { fix(draft) }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Fixes run as a simulation until the fleet is connected.")
                        .font(AppFont.caption()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .chatColumn(alignment: .leading)
        }
    }

    private var store: BotStore { BotStore(context: context) }
    private var bot: Bot? { message.conversation?.roleId.flatMap(store.bot(id:)) }

    private func file(_ draft: BugDraft) {
        guard let url = draft.issueURL else { return }
        Task {
            let copied = await copySnapshot()
            openURL(url)
            if let conversation = message.conversation {
                store.append(.system, copied ? "Opened a prefilled issue on GitHub. The preview screenshot is on your clipboard: paste it into the issue."
                                             : "Opened a prefilled issue on GitHub.", to: conversation)
            }
        }
    }

    private func fix(_ draft: BugDraft) {
        guard let bot else { return }
        store.proposeRun(task: "Fix: \(draft.described)", crew: .coder, on: bot)
    }

    private func copySnapshot() async -> Bool {
        guard let png = await preview.snapshotPNG() else { return false }
        #if os(iOS)
        guard let image = UIImage(data: png) else { return false }
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        #endif
        return true
    }
}
