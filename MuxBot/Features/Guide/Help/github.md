# GitHub

Mux Bot reads your repos' issues and pull requests, and opens pull requests for a bot's committed runs.

## Signing in

Sign in with GitHub in Settings. GitHub shows a code to enter on its site. The sign-in stays in this device's Keychain. Without it, Mux Bot can read public repos only, and fewer times an hour.

## Opening a pull request

When a bot's task has saved changes that aren't in a review yet, its thread offers Start review. You give the review a title and pick who checks it: the Reviewer crew, which runs once on this Mac and gives you a numbered list with Fix this on each item, or you yourself. Start review opens a pull request on GitHub first. The review stays pinned at the top of the thread, with Merge once GitHub says the change can go in. When the project's rules need another person's review first, or the project changed in the same places, the card says so with a link to GitHub. After a merge, your next change starts a new task from the project's main version. If the Mux Bot GitHub app isn't installed on the repo, the thread says so with the link to install it.
