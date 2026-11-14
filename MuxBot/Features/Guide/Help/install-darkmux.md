# Installing darkmux

darkmux is free and open source, and runs the models and the work on your Mac. Mux Bot can't install it for you, and it never asks you to type commands: its setup check links darkmux's guide (darkmux.com/guide), which shows how to get it.

## Install

In Mux Bot's setup check, Get darkmux opens darkmux's guide. Once darkmux answers on this Mac, the step ticks itself off.

## The app connection

Mux Bot talks to darkmux through its app connection on this Mac. When it isn't running, the setup check and the preview say so and link darkmux's guide, which shows how to start it; then Try again.

## Model engines and Docker

darkmux runs local models through a model engine on this Mac: Flint, TensorFold or LM Studio. You need one; darkmux's guide shows how to set it up. The setup check's "Models Mux Bot can use" step ticks off once darkmux lists a model that answers, whichever engine runs it. Until then, that step suggests one for this Mac: Flint, which runs privately on the Mac, when it has 48 GB of memory or more and about 30 GB free (Flint is a download of about 21 GB); otherwise a hosted model, which sends your prompts and code to its provider. It's a suggestion: any engine darkmux runs works.

LM Studio is optional. Mux Bot still sees whether it's installed: Get LM Studio opens its site, and Open LM Studio opens it when it's installed but not answering.

darkmux runs each piece of work in Docker Desktop, which pulls darkmux's image the first time. Mux Bot sees whether Docker Desktop is installed and open: Get Docker Desktop opens Docker's own install page, and Open Docker opens it when it's installed but closed.

## Which model fits

Pick a model that fits your Mac's memory (RAM). darkmux has settings tuned for 96 GB or more, for 33 to 64 GB, and for 32 GB or less; the setup check says which fits this Mac.
