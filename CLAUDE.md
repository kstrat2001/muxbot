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

## Rules

- **No third-party dependencies.** Apple frameworks only (SwiftUI, SwiftData, FoundationModels, ...).
- **Swift 6, strict concurrency complete.** UI state types are `@MainActor @Observable`.
- **Only bots act, and only after Approve.** Work starts in conversation: the one chat bar (`BotBar`) follows navigation and talks to the bot on screen (the lead bot, `LeadBot`, on Home). Dispatches to the crew, handoffs, new bots, new resources and, later, darkmux config changes are proposed as Approve / Cancel cards. The Work tab is read-only: no action buttons, only "Ask <bot> about this".
- **The run loop is human-in-the-loop, as thread cards** (`MessageKind`, `RunCardView`): dispatch card (Approve / Cancel) → live run card → result card (Keep / Tweak / Discard; Tweak sends a follow-up to the same run) → "Open PR" card after Keep. Transitions live in one state machine (`RunPhase.next(on:)`, applied by `BotStore.apply`). Runs are simulated until the fleet is connected.
- **The lead bot's name is a placeholder** (`LeadBot.name`, currently "Mux Bot"); change it there only.
- **The app owns its bot store.** A bot (`Bot`) is a project or theme: a persona, a thread, and resources (`BotResource`: repo, folder, preview recipe, link, note) and runs (`BotRun`). darkmux roles are the crew (`CrewRole`: Coder, Reviewer, Eval runner, Researcher): never bots or tiles, only named on dispatch cards and run details. Everything is in SwiftData, mutated through `BotStore`, not mirrored from darkmux config. First launch seeds humancodereader, darkmux, Personal brand and Daily update.
- **American English** in all copy, comments and docs.
- **The only network call is read-only GitHub** (`GitHubClient`: open issues and PRs for a bot's repo resources, unauthenticated REST, public repos, 60 requests an hour). No darkmux calls yet. Bots answer on device (`BotBrain`: Foundation Models guided generation with the `OpenIssuesTool` tool, over the bots and the fleet briefing). When the model is unavailable or fails (the simulator can report it available and still fail if the Mac has Apple Intelligence off), the thread says so once and `FallbackBrain` keyword matching answers: questions get honest answers, never a fake "Noted".

## Layout

- `MuxBot/App`: entry point, `ContentView` (Bots and Work tabs, sidebar on macOS/iPad), typed navigation (`AppRouter`, `Route`).
- `MuxBot/Core`: design system, the bot brain (`BotBrain`, `FallbackBrain`, `LeadBot`), models (bots, threads, `FleetSnapshot`), notification/background services, keychain, SwiftData container.
- `MuxBot/Features`: Home (lead bot card + bot tiles), Bots (`BotBar`, owned by the Bots tab and following `AppRouter.context`; `BotThreadView`; `BotInfoView` for resources; `NewBotView`), Work (`WorkView`, read-only runs grouped by bot, then mission: in progress, needs you, done), Chat (shared transcript UI).
- `MuxBotTests`: Swift Testing suites (`xcodebuild ... -destination 'platform=macOS' test`).
