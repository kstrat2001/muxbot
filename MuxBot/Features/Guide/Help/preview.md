# Live preview

A bot with a website can show it beside the chat. darkmux runs the site from its work copy, so you see each run's changes.

## Turning it on

The repo needs a preview recipe, .darkmux/preview.json, that says how to start it. Without one, you can add a preview link in the bot's info.

## Pointing at things

Use Pick in the preview and click an element, or select text and choose Chat about this. It goes into the chat bar, and what you type decides what happens: ask for a change ("make this bigger", "replace this with…") and the bot proposes the work for you to approve; describe a problem ("why is this cut off") and it measures the element and drafts a bug; ask a question ("what font is this") and it answers. Bots can't see the page, so they measure it instead.
