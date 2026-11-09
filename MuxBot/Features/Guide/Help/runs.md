# Runs

A run is one piece of work a bot sends to darkmux, like fixing an issue.

## How a run goes

1. You ask the bot, for example "fix #8".
2. It posts a dispatch card with what the crew gets. Nothing runs until you approve it.
3. The card shows the run live. You can stop it.
4. The result is the bot's reply: what changed, in plain words, with the diff under Details.

## Undo and changes

darkmux commits each finished run that changed files to the bot's branch. Undo reverts that run's commit. To change the result, just reply in the thread: your next message continues the same run.

## Questions

A run that changed nothing and stopped to ask shows its question, with buttons for its options.

## Done-when

When a run came from a measurement in the preview, Mux Bot measures again after the run and says whether the done-when was met. If it wasn't, Run again with these numbers sends it back.

## What needs you

Only approvals and questions need you. They show as a badge, in Activity, and pinned at the top of the thread.
