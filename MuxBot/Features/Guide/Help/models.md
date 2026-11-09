# Models

darkmux describes each way it can run a model as a profile: the model, its context size, and where it's served (LM Studio, or a model server on this Mac). Mux Bot picks a profile for each run.

## Which models Mux Bot can use

By default, darkmux lets a paired app use any profile that runs on this Mac. A profile that sends work to a hosted service or another machine needs your say-so on the Mac. You choose that in darkmux's config, not in Mux Bot.

## What the badges mean

In Settings › Models, each model in the Auto order shows whether it's ready here. Running means it answers now. Loads when used means LM Studio has it and darkmux loads it for the run. Not running means its server didn't answer. Not on this Mac means this Mac doesn't have that profile.

## Choosing the model

Settings › Models has three choices. Auto, the default, takes the first model in your Auto order that's running; if a run's done-when isn't met, Run again moves to the next one. Always ask shows a picker on each dispatch card, with Auto's pick ready. Always a model uses that model every time; if it isn't running, the card says so and offers Auto's pick instead.

## The Auto order

Put your fastest model first and a stronger one after it. Drag or use the arrows to reorder, and Add a model to add one this Mac has.

## Per machine, and per bot

Each Mac has its own models, so the choice is set per machine and shared with your other devices. A bot can use a different choice from its info.
