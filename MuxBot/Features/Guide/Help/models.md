# Models

darkmux describes each way it can run a model as a profile: the model, its context size, and where it's served (LM Studio, or a model server on this Mac). Mux Bot picks one for each run and shows it by its model and engine, like "Qwen3.8-27B-4bit · LM Studio". When several of darkmux's setups use the same model on the same engine, Mux Bot lists that model once.

## Which models Mux Bot can use

By default, darkmux lets a paired app use any profile that runs on this Mac. A profile that sends work to a hosted service or another machine needs your say-so on the Mac. You choose that in darkmux's config, not in Mux Bot.

## The order models are listed in

On a Mac, the model lists are ordered by fit: models that did well in the public evals at evals.darkmux.com on Macs with the same chip come first, and models without runs there follow in darkmux's order. It's only an order; no scores are shown. A model that has runs there goes by the name the evals site gives it.

## What the badges mean

In Settings › Models, each model in the Auto order shows whether it's ready here. Running means it's loaded now. Starts when used means darkmux loads the model or starts its server for the run. Not available means darkmux can't run it here; hover to see why. Not on this Mac means this Mac doesn't have that model.

## Choosing the model

Settings › Models has three choices. Auto, the default, takes the first model in your Auto order that's running; if a run's done-when isn't met, Run again moves to the next one. Always ask shows a picker on each dispatch card, with Auto's pick ready. Always a model uses that model every time; if it isn't running, the card says so and offers Auto's pick instead.

## The Auto order

The Auto order starts empty, so until you add a model, Auto uses darkmux's own choice. Put your fastest model first and a stronger one after it. Drag or use the arrows to reorder, and Add a model to add one this Mac has.

## Before you approve

Each dispatch card says which model and engine the run will use, and why. Change switches it for that run only. The result's Details say which model it ran on.

## Per machine, and per bot

Each Mac has its own models, so the choice is set per machine and shared with your other devices. A bot can use a different choice from its info.

A model that can't run right now still shows in the list, grayed out, with the reason. For example, when Flint's own server is already running on your Mac, darkmux can't start another one until that server is stopped.
