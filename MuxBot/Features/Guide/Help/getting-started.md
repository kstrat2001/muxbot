# Getting started

Mux Bot sends coding work to AI models running on your own Mac, through darkmux. You talk to a bot in its thread; it proposes work as a card, and nothing runs until you approve it.

## What you need

- A Mac with Apple silicon. Runs happen on the Mac; the iPhone and iPad apps show your bots and threads, and start runs from the Mac app for now.
- darkmux, the free command-line tool that runs local models and the work.
- LM Studio with at least one model downloaded.
- Docker Desktop, which darkmux uses to run each piece of work in a container.
- Mux Bot paired with darkmux on that Mac.

## Check your setup

Ask Mux Bot "check my setup". It shows a checklist that ticks itself off as each part starts working. At the top is one block to paste into Terminal that installs everything still missing (it needs Homebrew), with a rough time and download estimate; each step also has its own command.

## Your first project

With no bots yet, Mux Bot opens on "What do you want to get done?". Pick a use case, such as Build a website, and answer its questions: the name, what it's for, and how it should feel (tap a suggestion or write your own). Each project gets its own repo in your GitHub account, so sign in to GitHub first: it's private unless you switch Public on, and it starts with the template's files. Then darkmux makes the project on this Mac and the preview starts. The bot's committed work is backed up to its own branch on that repo, and Open PR asks to merge it. The new bot's first message offers a first change written from your answers; tap Approve to see it in the preview.

## Your first bot for code you have

A bot is a project you name, like your website. In "What do you want to get done?", choose Work on a project I already have, then a folder on this Mac or a repo on your GitHub (sign in to see your repos). Mux Bot suggests a name and asks what the project is. darkmux makes its own copy on a new branch, so your files aren't touched. A preview runs only from your own checkout: a folder on this Mac gets one, and a repo darkmux clones doesn't until you add your checkout with Add folder. The bot's skills come from the project's own PLAYBOOK.md if it has one, else general ones. Without one, the bot offers a PLAYBOOK.md for your checkout to edit and approve; its persona and conventions are drafted on this device from your README when Apple Intelligence is on. When a project has no preview recipe, the bot offers one worked out from its package.json, also to edit and approve. Either file is written into your folder, uncommitted, never over one that's there, and goes into the bot's next pull request.

You can also ask Mux Bot "make a bot for my repo" and paste a GitHub link, or use New bot in the More menu.
