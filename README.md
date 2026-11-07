# Mux Bot

Mux Bot: the friendly, free, open-source app for [darkmux](https://github.com/kstrat2001/darkmux). iOS and macOS.

Ask a bot to fix an issue in your repo, tap Approve, and watch a model on your own Mac make the change, with a live preview of the site. Keep the change or discard it. Nothing runs until you approve it.

## Early preview

Mux Bot needs a darkmux feature that isn't released yet: an app endpoint for pairing, runs, work copies and previews. Its design is being discussed in [darkmux#3447](https://github.com/kstrat2001/darkmux/issues/3447). You can try it now from a preview branch. Expect rough edges.

### You'll need

- A Mac with Apple silicon, on macOS 26 with Apple Intelligence turned on (the bots answer on device)
- A working darkmux setup: LM Studio, a model profile bound to the `coder` role, and Docker
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- git access to the repos you want bots to work on
- For live previews: a `.darkmux/preview.json` recipe in the repo

### 1. Install the preview darkmux

This installs into its own folder and leaves any darkmux you already have alone:

```bash
cargo install --git https://github.com/kstrat2001/darkmux --branch claude/project-thread-ey1ov3 \
  --root ~/.local/darkmux-client-preview darkmux
~/.local/darkmux-client-preview/bin/darkmux client serve
```

The endpoint listens on `127.0.0.1` only. If you also use a released darkmux (5.9.1 or earlier), leave the new `clients.profiles` setting unset, because older releases refuse a config that has it.

### 2. Build and run the app

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your DEVELOPMENT_TEAM
xcodegen generate
open MuxBot.xcodeproj
```

Run the MuxBot scheme on "My Mac".

### 3. Pair

In the app, choose **Pair with darkmux** and run the approve command it shows:

```bash
~/.local/darkmux-client-preview/bin/darkmux client approve <CODE>
```

Then make a bot, use **Add folder** to pick a checkout of your repo, and ask it to fix an issue. darkmux works in its own copy of your repo on a separate `mux/…` branch, so your working tree is never touched.

### Not there yet

- The iPhone app can chat but can't start runs; runs start from the Mac app.
- The app can't open pull requests yet. Keep commits the change to the work copy's branch, and you push it.
- iCloud sync is built but turned off until it's tested.

## License

MIT
