import SwiftUI
import UniformTypeIdentifiers

/// Where the preview panel goes while darkmux starts the preview, why it
/// didn't start, or why darkmux won't run one (with its fix, when there is one).
struct PreviewStatusView: View {
    let preview: LivePreview
    let bot: Bot
    let retry: () -> Void

    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(\.modelContext) private var context
    @State private var pickingFolder = false
    @State private var folderProblem: String?
    @State private var addingFolder = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            if router.previewFullScreen {
                // Full window with no page yet: still a way back (Esc).
                HStack {
                    Spacer()
                    Button("Show chat", systemImage: "arrow.down.right.and.arrow.up.left") { router.previewFullScreen = false }
                        .keyboardShortcut(.cancelAction)
                        .help("Back to chat (Esc)")
                }
            }
            switch preview.status {
            case .waiting, .starting, .installing, .settingUpWorkCopy:
                ProgressView()
                Text(preview.status.text).foregroundStyle(Color.secondaryText)
            case let .failed(reason):
                let failure = PreviewFailure(reason: reason, log: preview.log)
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.brandOrange)
                    .accessibilityHidden(true)
                Text(failure.headline).font(.headline).multilineTextAlignment(.center)
                Text(failure.explanation).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                startOverOrRetry(failure)
                // What darkmux and the project's server said, only when asked.
                TechnicalDetails(text: failure.details)
            case let .unavailable(why):
                unavailable(why)
            case .ready, .stopped:
                Text(preview.status.text).foregroundStyle(Color.secondaryText)
                Button("Start", systemImage: "play", action: retry)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Whether darkmux can start the preview over (#45).
        .task(id: preview.status) { await brain.runs.checkStartOver() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task {
                addingFolder = true
                defer { addingFolder = false }
                folderProblem = await brain.runs.addFolder(url, to: bot, store: BotStore(context: context))
                if folderProblem == nil { retry() }
            }
        }
    }

    /// Try again restarts the preview; Start over (where darkmux can) also
    /// reinstalls the project's packages, and leads for install problems.
    @ViewBuilder
    private func startOverOrRetry(_ failure: PreviewFailure) -> some View {
        let canStartOver = brain.runs.canStartOver
        HStack {
            if canStartOver, failure.startOverFirst {
                Button("Start over", systemImage: "arrow.counterclockwise", action: startOver)
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            } else {
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                if canStartOver { Button("Start over", systemImage: "arrow.counterclockwise", action: startOver) }
            }
        }
        if canStartOver {
            Text(PreviewFailure.startOverNote).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private func startOver() { Task { await brain.runs.startOver(for: bot) } }

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
            HStack {
                guideLink
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
            }
        case .notYourCheckout, .checkoutMoved:
            if addingFolder {
                ProgressView("Setting up a work copy…")
            } else {
                Button("Add folder…", systemImage: "folder.badge.plus") { pickingFolder = true }
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
            }
            if let folderProblem { Label(folderProblem, systemImage: "exclamationmark.triangle").labelStyle(.tintedIcon(Color.brandOrange)).multilineTextAlignment(.center) }
        case .noRecipe:
            HStack {
                Button("Set up preview", systemImage: "play.rectangle") { brain.offerPreviewSetup(for: bot, store: BotStore(context: context)) }
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            }
        case .newProject:
            EmptyView()
        case .notAnswering:
            HStack {
                guideLink
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
            }
        case .templateNoRecipe:
            EmptyView()
        case .remakeProject:
            Button("Start a project…", systemImage: "plus") { router.showStartProject = true }
                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
        case .notPaired:
            Button("Pair with darkmux…", systemImage: "link") { router.showPairing = true }
                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
        case .earlierPairing:
            HStack {
                Button("New work copy", systemImage: "arrow.triangle.branch") {
                    Task { await brain.runs.newWorkCopy(for: bot, store: BotStore(context: context)) }
                }
                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            }
        }
    }

    /// What darkmux needs on this Mac, from its own guide (never a command).
    private var guideLink: some View {
        Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }
    }
}

/// Raw output (a log, a service's reply) for bug reports: closed by default,
/// with Copy. Never the first thing anyone reads.
struct TechnicalDetails: View {
    let text: String
    @State private var shown = false
    @State private var copied = false

    var body: some View {
        DisclosureGroup("Show details", isExpanded: $shown) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ScrollView {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(Spacing.sm)
                .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground))
                Button(copied ? "Copied" : "Copy details", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(text)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .font(AppFont.footnote())
        .foregroundStyle(Color.secondaryText)
        .frame(maxWidth: 480)
    }
}
