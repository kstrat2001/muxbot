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
- **Radio is the only way to start work.** Role screens never get a task input; they link back to Radio ("New work? Ask Radio").
- **The app owns its role store.** Roles live in the app's SwiftData store (`MuxRole`, `RoleTask`, mutated through `RoleStore`), not as a mirror of darkmux config. First launch seeds Coder, Reviewer, Eval runner and Researcher.
- **American English** in all copy, comments and docs.
- No networking or darkmux calls exist yet. Radio plans on device (`RadioPlanner`: Foundation Models guided generation, keyword fallback labeled in the UI); Approve only records a local task.

## Layout

- `MuxBot/App`: entry point, `ContentView`, typed navigation (`AppRouter`, `Route`).
- `MuxBot/Core`: design system, on-device LLM + generic `ChatService`, models, notification/background services, keychain, SwiftData container.
- `MuxBot/Features`: Home (role tiles + Radio dock), RoleChat, Roles (new role form), Chat (shared transcript UI).
- `MuxBotTests`: Swift Testing suites (`xcodebuild ... -destination 'platform=macOS' test`).
