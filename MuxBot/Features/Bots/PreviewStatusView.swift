import SwiftUI
import UniformTypeIdentifiers

/// Where the preview panel goes while darkmux starts the preview, why it
/// didn't start, or why darkmux won't run one (with its fix, when there is one).
struct PreviewStatusView: View {
    let preview: LivePreview
    let bot: Bot
    let retry: () -> Void

    @Environment(BotBrain.self) private var brain
    @Environment(\.modelContext) private var context
    @State private var pickingFolder = false
    @State private var folderProblem: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            switch preview.status {
            case .waiting, .starting, .installing:
                ProgressView()
                Text(preview.status.text).foregroundStyle(Color.secondaryText)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.brandOrange)
                Text(preview.status.text).multilineTextAlignment(.center)
                if let log = preview.log, !log.isEmpty {
                    ScrollView {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground))
                }
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            case let .unavailable(why):
                unavailable(why)
            case .ready, .stopped:
                Text(preview.status.text).foregroundStyle(Color.secondaryText)
                Button("Start", systemImage: "play", action: retry)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task {
                folderProblem = await brain.runs.addFolder(url, to: bot, store: BotStore(context: context))
                if folderProblem == nil { retry() }
            }
        }
    }

    @ViewBuilder
    private func unavailable(_ why: LivePreview.Unavailable) -> some View {
        Image(systemName: why == .previewsOff ? "eye.slash" : "doc.questionmark")
            .font(.largeTitle).foregroundStyle(Color.secondaryText)
            .accessibilityHidden(true)
        Text(why.title).font(.headline).multilineTextAlignment(.center)
        Text(why.detail(repo: bot.repoSlugs.first, folder: bot.folderName))
            .foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        switch why {
        case .previewsOff:
            Text(LivePreview.Unavailable.enableCommand)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(Spacing.sm)
                .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground))
            HStack {
                Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(LivePreview.Unavailable.enableCommand)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            }
        case .notYourCheckout:
            Button("Add folder…", systemImage: "folder.badge.plus") { pickingFolder = true }
                .buttonStyle(.borderedProminent)
            if let folderProblem { Text(folderProblem).foregroundStyle(Color.brandOrange).multilineTextAlignment(.center) }
        case .noRecipe:
            Button("Try again", systemImage: "arrow.clockwise", action: retry)
        case .newProject:
            EmptyView()
        }
    }
}
