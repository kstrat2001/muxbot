# Mux Bot: agent instructions

Mux Bot is the friendly, free, open-source app for darkmux (iOS and macOS, one SwiftUI multiplatform target).

## Build

The Xcode project is generated and gitignored. Never edit or commit `MuxBot.xcodeproj`; change `project.yml`.

```bash
xcodegen generate
xcodebuild -project MuxBot.xcodeproj -scheme MuxBot -destination 'generic/platform=iOS Simulator' build
xcodebuild -project MuxBot.xcodeproj -scheme MuxBot -destination 'platform=macOS' build
```

Both builds must pass before a push. Signing: `DEVELOPMENT_TEAM` is never committed (forks are encouraged). Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored), or set the team in Xcode.

## Design philosophy

Mux Bot is about getting work done, not managing machines. Lead with the work (runs, results, what needs you); machines, models and config appear only as details of a run or in conversation with a bot. Only bots act, always behind an Approve card; other screens are read-only. Bots are projects or themes the user names; darkmux roles are the crew underneath. Status is shown with icons and motion, not words (`StatusBadge`; words only in accessibility labels).

Use Apple's built-in frameworks wherever they fit, before writing custom code: CloudKit for sync, Keychain (and Secure Enclave / CryptoKit for pairing keys), Foundation Models, App Intents, WidgetKit and ActivityKit, UserNotifications, LocalAuthentication, Handoff, Speech.

## Rules

- **No third-party dependencies.** Apple frameworks only, and prefer a system framework over custom code (see the design philosophy).
- **Swift 6, strict concurrency complete.** UI state types are `@MainActor @Observable`.
- **Only bots act, and only after Approve.** Work starts in conversation: the one chat bar (`BotBar`) follows navigation and talks to the bot on screen (the lead bot, `LeadBot`, on Home). Dispatches to the crew are run cards; handoffs, new bots and new resources are action cards (`MessageKind.actionCard`, `ActionCardView`, decided once by `BotBrain.resolve`). All are saved in the thread, so several can wait at once and they survive a relaunch. The Activity tab is read-only: a row opens its run's card in the bot's thread.
- **The run loop is human-in-the-loop, as thread cards** (`MessageKind`, `RunCardView`): dispatch card (Approve / Cancel) → live run card → result card (Keep / Tweak / Discard; Tweak sends a follow-up to the same run) → "Open PR" card after Keep. Transitions live in one state machine (`RunPhase.next(on:)`, applied by `BotStore.apply`). Nothing is ever simulated: a run that can't go to darkmux doesn't start, and a refused submit fails the run (`.fail`), never a result to Keep. Tweak re-sends the original brief, the files changed and the requested change. Keep has darkmux commit exactly the run's changed files to the work copy's branch, and Discard has it put them back (the card moves only after darkmux did it, and says what it did); a tweak's changes are cumulative with the run it continues.
- **Live preview** (`PreviewPanel`, SwiftUI `WebView`): a bot thread shows a Preview toggle when the bot has a preview URL; split beside the chat on macOS/iPad, above it on iPhone; a run card's "Live" opens it. The bot info sheet checks each repo for `.darkmux/preview.json` (from the bot's workspace through darkmux, else read-only from GitHub). darkmux runs a bot's preview in its work copy from the repo's `.darkmux/preview.json` (`command`, `env` with `{port}`/`{hmrPort}`, `ready`, `install`, `env_from_source`) on its own free ports, and the app shows its URL once ready (`LivePreview`, `BotBrain.ensurePreview`; the panel shows `PreviewStatusView` while it starts or if it failed). Without a work copy, a preview link you add is shown instead (never commit a tailnet hostname). ATS allows plain http for `*.ts.net` only, until tailnet HTTPS certificates are on.
- **Work copies belong to darkmux.** A bot keeps its GitHub repo, and on this Mac a darkmux workspace name (`Bot.workspaceName`), never a path. Add folder (Open panel, security-scoped bookmark, `GitRemote` reads the repo from its git config) has darkmux make a worktree of your checkout on its own `mux/<bot>-<id>` branch from the fetched default branch, so your working tree is never touched; with no folder, darkmux clones the repo. A dispatch card for a bot with code but no workspace asks "Set up … on this Mac?" first (`RunBlocker`).
- **Bots can't see; they measure.** A described visual problem is a bug report, never judged by the model: `BugReport` runs `factsScript` in the preview (`PreviewController`, `PageInspecting`) to measure the matching element, then posts a bug card (`BugCardView`): "File on GitHub" (prefilled issue URL, preview screenshot on the clipboard) or "Fix it now" (a Coder dispatch card).
- **Point, don't describe.** In the preview, Pick (hover, click) or select text → "Ask about this" / "Report a bug here" attaches the element (`PickedElement`: selector, measurements, cropped snapshot) as a chip in the bar for one message (`BugReport.pageScript`, installed on every load, and `pickerScript` post picks to the app through a WebKit message handler; `PreviewController`, `PickRelay`).
- **Intents:** inferred by default (`Intent.infer`), or set with a prefix (`bug:`, `fix:`, `review:`, `ask:`, `issues:`). A correction like "no, it's a question" re-answers your previous message under that intent (`Intent.correction`). `ask` never proposes work.
- **Repo hints come from the repo.** A run's brief adds the repo's own `conventions` and `page_file` from its `.darkmux/preview.json` (`PreviewManifest`); the app never guesses a framework's layout.
- **The lead bot's name is a placeholder** (`LeadBot.name`, currently "Mux Bot"); change it there only.
- **The app owns its bot store.** A bot (`Bot`) is a project or theme: a persona, a thread, resources (`BotResource`: repo, preview link, link, note; folders come only from Add folder) and runs (`BotRun`). darkmux roles are the crew (`CrewRole`: Coder, Reviewer, Eval runner, Researcher): never bots or tiles, only named on dispatch cards and run details. Everything is in SwiftData, mutated through `BotStore`, not mirrored from darkmux config. Nothing is seeded: an empty Home offers one example bot on request (`BotStore.addExample`), so a second device syncing the same iCloud data never duplicates bots.
- **Versioned schema** (`MuxBot/Core/Models/Schema`): `SchemaV1` is the frozen pre-versioning store; `SchemaV2` is the live models; `MuxBotMigrationPlan` moves between them. Change a model only by adding a new version and stage, with a test that migrates a real on-disk store. A store that won't open shows `StoreRecoveryView` (Try again, or Start fresh, which renames the old files and never deletes them).
- **Sync and machine-local data:** with `MUXBOT_CLOUD_SYNC = YES` and the iCloud entitlements (see `Config/Local.xcconfig.example`), bots, runs and threads sync through the user's private CloudKit database; models stay CloudKit-safe (no unique constraints, defaults or optionals, optional relationships; a test checks). What belongs to one machine (darkmux workspace name, picked folder bookmark) lives in `LocalBotState` (a file in the app's container, keyed by bot id), never in the synced store. The pairing token stays in this device's Keychain.
- **American English** in all copy, comments and docs.
- **Network calls:** read-only GitHub (`GitHubClient`: issues and PRs for a bot's repo, unauthenticated REST, public repos, 60 requests an hour), and darkmux's local client endpoint on this Mac (`DarkmuxClient`, `127.0.0.1:8767`, prototype contract on a local darkmux build): pairing (`FleetConnection`, token in the Keychain), workspaces, runs, status, cancel and the preview recipe. The iPhone app can't reach it yet; it says runs start from the Mac app.
- **Bots answer on device** (`BotBrain`: Foundation Models guided generation with the `OpenIssuesTool` tool). The app can't see the darkmux fleet yet, and bots say so rather than guess. When the model is unavailable or fails (the simulator can report it available and still fail if the Mac has Apple Intelligence off), the thread says so once and `FallbackBrain` keyword matching answers: honest answers, never a fake "Noted".

## Layout

- `MuxBot/App`: entry point, `ContentView` (macOS/iPad: `BotSidebar` of Mux Bot, bots, Activity, with the thread beside it; iPhone: Bots and Activity tabs), typed navigation (`AppRouter`, `Route`).
- `MuxBot/Core`: design system, the bot brain (`BotBrain`, `FallbackBrain`, `LeadBot`), models (bots, threads, runs), services (`DarkmuxClient`, `FleetConnection`, `GitHubClient`, notifications), keychain, SwiftData container.
- `MuxBot/Features`: Home (lead bot card + bot tiles), Bots (`BotBar`, owned by the Bots tab and following `AppRouter.context`; `BotThreadView`; `BotInfoView` for resources; `NewBotView`), Activity (`ActivityView`, read-only runs in three groups: needs you, running, finished; a sortable table on macOS), Chat (transcript, run cards, action cards, bug cards).
- `MuxBotTests`: Swift Testing suites (`xcodebuild ... -destination 'platform=macOS' test`). They run inside the app (its test host), which then uses an in-memory store: tests must never open the real one.
- `MuxBotUITests`: XCUITests on an iOS simulator (`-destination 'platform=iOS Simulator,id=<iPad>' test -only-testing:MuxBotUITests`); the app launches with `-uiTesting` (in-memory store, one example bot with a blank preview). macOS UI tests need an accessibility permission, so they run on iOS.
- User-facing strings live in `MuxBot/Resources/Localizable.xcstrings` (synced from the build with `xcrun xcstringstool sync`).
