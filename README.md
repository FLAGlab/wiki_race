# WikiRace Competition Platform

## Overview

WikiRace is a project for a university course on concurrency, distribution, and
parallelism. Each group writes a web crawler in Elixir. In each match, two crawlers race
to find a path of links between two Wikipedia articles. They must follow the links. They
may not use a search API.

This repo holds the whole system. The platform starts the race, shows the progress of
both crawlers, checks every path they report, and scores the result. You do not change
the platform. You only write the crawler, in `player/`.

You get the full repo so you can test your crawler on your own PC, with the same platform
that scores it on competition day.

## Where to start

| File               | What it explains                                 |
| ------------------ | ------------------------------------------------ |
| `player/README.md` | What you must implement.                         |
| `RUNNING.md`       | How to run a race on your PC.                    |
| `SCORING.md`       | How a race is scored.                            |
| `DEPLOY.md`        | How the professor runs the tournament. Optional. |

## Rules

- Your crawler is a plain OTP application. The only libraries you may add are Req (to
  fetch pages) and Floki (to parse HTML).
- Concurrency, coordination, and distribution must use OTP: GenServer,
  DynamicSupervisor, ETS, and Erlang distribution. No crawler or job queue libraries.
- Your crawler reads pages only from the offline copy of Wikipedia. Never request the
  real wikipedia.org.

The rules are strict on purpose. The course is about concurrency and distribution, so
your crawler must build them with the tools the course teaches.

## How a competition works

Each group ships their crawler as an Elixir OTP application on GitHub. It must
implement a behavior with two functions: `start(start_url, target_url)`, which
returns a pid, and `status(pid)`, which returns the crawler's current state.

On competition day there are four machines on a private network:

- **Wikipedia VM.** Runs Kiwix, which serves an offline copy of English Wikipedia.
  Crawlers fetch pages from here.
- **Platform VM.** Runs the Phoenix app in `platform/`. It is the referee (the
  "harness") and shows the live dashboard.
- **Two player VMs.** One for each group in a match. Each one runs the crawler of a
  group.

The steps are:

1. Before the tournament, the professor deploys the crawler of every group from its
   GitHub repository. Each match starts the crawlers of its two groups, each one alone on
   its own player VM.
2. For each match, the professor clicks "Start race".
3. Both crawlers receive the same start and target articles at the same moment.
4. The dashboard shows the progress of both crawlers.
5. The race ends when both crawlers are done, or after 120 seconds.

## Grading

Matches are 1v1. Each crawler gets a score from its race. The score rewards:

- finding a valid path,
- finding it before the other crawler,
- a short path,
- a fast time, and
- good use of the schedulers.

Speed counts more than path length. A wrong path scores -1.0. `SCORING.md` gives the
exact points.

The tournament has four rounds. In each round, groups with similar results play each
other, and no two groups play twice. With an odd number of groups, one group races alone
in each round (a bye). A bye is scored like any race.

## Running it on your PC

`make up` runs the four machines as four Docker containers:

| Container            | Stands in for      |
| -------------------- | ------------------ |
| `kiwix1`             | the Wikipedia VM   |
| `platform`           | the platform VM    |
| `player1`, `player2` | the two player VMs |

`player1` and `player2` both run your `player/` folder, so your crawler races against
itself. `RUNNING.md` has the steps.

## The platform

These screenshots come from a demo race on the local setup. They were taken with an
earlier version of the score.

`/admin` is where the professor picks the articles and starts each match.

![Race control on /admin](docs/screenshots/admin.png)

`/schedule` shows the matches of the current round.

![The schedule of the current round](docs/screenshots/schedule.png)

During a race, the dashboard at `/` shows both crawlers side by side.

![A race in progress](docs/screenshots/race-running.png)

When a crawler reports a path, the harness checks it link by link. At the end, each side
shows its hops, its time, its scheduler use, its score, and its path.

![A finished race with both paths verified](docs/screenshots/race-finished.png)

`/standings` ranks the groups and shows how the score is built.

![Standings and the score formula](docs/screenshots/standings.png)

## Technology

Phoenix LiveView for the harness and the dashboard. Erlang distribution between nodes.
Kiwix serves Wikipedia. Docker Compose runs everything locally.
