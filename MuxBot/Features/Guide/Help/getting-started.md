# Getting started

Mux Bot sends coding work to AI models running on your own Mac, through darkmux. You talk to a bot in its thread; it proposes work as a card, and nothing runs until you approve it.

## What you need

- A Mac with Apple silicon. Runs happen on the Mac; the iPhone and iPad apps show your bots and threads, and start runs from the Mac app for now.
- darkmux, the free tool that runs local models and the work.
- A model engine darkmux runs models with: Flint, TensorFold or LM Studio. darkmux's guide shows how to set one up.
- Mux Bot paired with darkmux on that Mac.

## Check your setup

Ask Mux Bot "check my setup". It shows a checklist that ticks itself off as each part starts working. Each step has a button or a link: darkmux's guide for darkmux itself and for setting up a model engine, and Open LM Studio or its download page for the optional LM Studio row. LM Studio and GitHub are optional rows that don't count toward "All set". Nothing asks you to type a command.

## Your first project

With no bots yet, Mux Bot opens on "What do you want to get done?". Pick a use case, such as Build a website, and answer its questions: the name, what it's for, and how it should feel (tap a suggestion or write your own). GitHub is optional. Back up to GitHub is off until you sign in to GitHub in Mux Bot, then on unless you switch it off (your last choice is kept): the project also gets its own repo in your GitHub account (sign in first), private unless you switch Public on, starting with the template's files, with the bot's committed work backed up to its own branch there and Review & merge to check it and merge it. Switched off, your project stays on this Mac; you can put it on GitHub later from the bot's info. Then darkmux makes the project on this Mac and the preview starts. The new bot's first message offers a first change written from your answers; tap Approve to see it in the preview.

## Your first bot for code you have

A bot is a project you name, like your website. In "What do you want to get done?", choose Work on a project I already have, then a folder on this Mac or a repo on your GitHub (sign in to see your repos). Mux Bot suggests a name and asks what the project is. darkmux makes its own copy on a new branch, so your files aren't touched. A preview runs only from your own checkout: a folder on this Mac gets one, and a repo darkmux clones doesn't until you add your checkout with Add folder. The bot's skills come from the project's own PLAYBOOK.md if it has one, else general ones. Without one, the bot offers a PLAYBOOK.md for your checkout to edit and approve; its persona and conventions are drafted on this device from your README when Apple Intelligence is on. When a project has no preview recipe, the bot offers one worked out from its package.json, also to edit and approve. Either file is written into your folder, uncommitted, never over one that's there, and goes into the bot's next pull request.

You can also ask Mux Bot "make a bot for my repo" and paste a GitHub link, or choose New and then Just a bot, no project.
