# Pairing with darkmux

Pairing lets Mux Bot send work to darkmux on this Mac. You approve it once in Terminal, and you can revoke it any time.

## How to pair

1. Start darkmux's app connection in Terminal: darkmux client serve. Leave it running.
2. In Mux Bot, choose Pair with darkmux. It shows a code.
3. In another Terminal window, run darkmux client approve and check the code matches.

Mux Bot keeps the pairing in this device's Keychain. It's never synced. If you have no bots yet, Mux Bot goes on to "What do you want to get done?" once it's paired.

## Unpairing

Choose Unpair this app in Mux Bot's darkmux settings, or revoke it in Terminal with darkmux client revoke.

## iPhone and iPad

On iPhone and iPad this sheet is called Your Mac and GitHub. Runs start from the Mac app for now, so pair Mux Bot on the Mac where darkmux runs; pairing your phone over your own network comes later. GitHub sign-in is there too. Until Mux Bot on your Mac has answered once, the model settings stay off: open Mux Bot on your Mac once to see its models.

## When darkmux can't be reached

If Mux Bot says it can't reach darkmux, the app connection isn't running on this Mac. Start it again with darkmux client serve.
