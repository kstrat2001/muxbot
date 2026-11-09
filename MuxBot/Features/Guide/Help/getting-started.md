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

With no bots yet, Mux Bot opens on "What do you want to get done?". Pick a use case, such as Build a website, and answer its questions: the name, what it's for, and how it should feel (tap a suggestion or write your own). darkmux makes the project on this Mac and the preview starts. The new bot's first message offers a first change written from your answers; tap Approve to see it in the preview.

## Your first bot for code you have

A bot is a project you name, like your website. Ask Mux Bot "make a bot for my repo" and paste a GitHub link, or use New bot (in the More menu) and add a project folder.
