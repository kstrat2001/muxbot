# Installing darkmux

darkmux is a free, open-source command-line tool from Homebrew. Mux Bot can't install it for you (apps can't run commands on your Mac), so you run these in Terminal.

## Install

Install it with Homebrew:

    brew tap kstrat2001/tap
    brew install darkmux

Then set it up and check it:

    darkmux init
    darkmux doctor

darkmux init writes its config and model profiles without overwriting anything you already have. darkmux doctor checks LM Studio, your models, Docker and your Mac's memory, and says what's missing.

## The app connection

Mux Bot talks to darkmux through its app connection on this Mac, started with darkmux client serve. It isn't in a darkmux release yet (5.9.3 doesn't have it); it comes in the next one. Until then, it needs a build of darkmux that has it.

## LM Studio and Docker

darkmux runs local models in LM Studio (lmstudio.ai); download at least one model there. It runs each piece of work in Docker (docker.com), which pulls darkmux's image the first time.

## Which model fits

Pick a model that fits your Mac's memory (RAM). darkmux has settings tuned for 96 GB or more, for 33 to 64 GB, and for 32 GB or less; darkmux doctor says whether what you picked fits.
