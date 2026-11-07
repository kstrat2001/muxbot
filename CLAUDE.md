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

## Rules

- **No third-party dependencies.** Apple frameworks only (SwiftUI, SwiftData, FoundationModels, ...).
- **Swift 6, strict concurrency complete.** UI state types are `@MainActor @Observable`.
- **Only bots act, and only after Approve.** Work starts in conversation: the one chat bar (`BotBar`) follows navigation and talks to the bot on screen (the lead bot, `LeadBot`, on Home). Handoffs, new bots and, later, dispatch and darkmux config changes are proposed as Approve / Cancel cards. The Fleet tab is read-only: no action buttons, only "Ask <bot> about this".
- **The lead bot's name is a placeholder** (`LeadBot.name`, currently "Mux Bot"); change it there only.
- **The app owns its role store.** The UI calls roles **bots** (Mux Bot); code and darkmux call them roles (`MuxRole`). Roles live in the app's SwiftData store (`MuxRole`, `RoleTask`, mutated through `RoleStore`), not as a mirror of darkmux config. First launch seeds Coder, Reviewer, Eval runner and Researcher.
- **American English** in all copy, comments and docs.
- No networking or darkmux calls exist yet. Bots answer on device (`BotBrain`: Foundation Models guided generation over the bots and the fleet briefing; `FallbackBrain` keyword matching, labeled in the UI, when the model is unavailable). The fleet is `FleetSnapshot.sample`, labeled as sample data.

## Layout

- `MuxBot/App`: entry point, `ContentView` (Bots and Fleet tabs, sidebar on macOS/iPad), typed navigation (`AppRouter`, `Route`).
- `MuxBot/Core`: design system, the bot brain (`BotBrain`, `FallbackBrain`, `LeadBot`), models (bots, threads, `FleetSnapshot`), notification/background services, keychain, SwiftData container.
- `MuxBot/Features`: Home (lead bot card + bot tiles), Bots (`BotBar`, owned by the Bots tab and following `AppRouter.context`; `BotThreadView`), Fleet (read-only tab), Roles (New bot form), Chat (shared transcript UI).
- `MuxBotTests`: Swift Testing suites (`xcodebuild ... -destination 'platform=macOS' test`).
