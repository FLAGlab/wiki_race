# The tournament roster's deployment manifest.
#
# Each entry is a group whose crawler the platform can build a release for
# and ship to a player VM. `repo`/`tag`/`sha` document where and when the
# code was cloned by hand at the deadline. `path` is where that clone
# actually lives on this host, which is what the release build and
# everything after it reads from.
#
# `app` is the group's OTP application name, exactly as declared in their
# `mix.exs`'s `app:` key. `Deploy.Manifest.check_groups/0` verifies the two
# actually match, since a typo here fails silently otherwise (the release
# build succeeds under whatever name their mix.exs declares, but a wrong
# `app` here means `Deploy.Release`/`Deploy.Server` look for the wrong
# binary and script paths afterward).
#
# `module` overrides automatic crawler-module discovery
# (`WikiRacePlatform.Race.Discovery`). Leave `nil` unless a group's
# `WikiRace.Crawler` implementation can't be found by scanning loaded
# modules.
#
# `host`/`node` are this group's player VM and the Erlang node name their
# release runs under once deployed. They're optional: leave `nil` and pass
# `--host`/`--node` to `mix wiki_race.deploy` by hand instead. But without
# them `ScheduleLive` can't auto-resolve this group's node when starting a
# tournament race, and `mix wiki_race.start`/`.stop` need them supplied
# explicitly too. `name` must match this group's entry in the tournament
# roster (`config :wiki_race_platform, :tournament, roster: [...]`) for
# that auto-resolution to find it.
#
# "Local fixture" is the in-repo `player/` skeleton, checked by
# `test/wiki_race_platform/deploy/manifest_test.exs` and `server_test.exs`.
# Keep it here even when adding real (or test) groups below.
#
# "player1"/"player2" are docker-compose's dev-loop nodes (see
# docker-compose.yml's NODE_NAME for each), not deployed groups; nothing
# here ever calls `mix wiki_race.deploy` for them either. They only exist
# so `config/dev.exs`'s roster override can resolve them to real,
# connected nodes and let `/admin` race them out of the box.
#
# The three "Mutex Maniacs"/... entries below are a local test fixture, not
# real groups: three nodes all running this same platform app
# (`START_HARNESS=false`, inside the `platform` container), enough to
# exercise tournament pairing and dispatch across more than two nodes.
# None of them has a crawler to discover, so a dispatched race against
# them ends the same way an untouched `player/` checkout does.
# `path`/`app` point at `player/` anyway so `Deploy.Manifest.check_groups/0`
# still has something real to check; they're not actually used to
# build/ship anything for this fixture, since nothing here ever calls
# `mix wiki_race.deploy`.
#
# On the university VMs (`WIKI_RACE_VMS=true`, set by `deploy/final/wikirace`)
# the manifest is only the groups of `deploy/final/groups.txt`, cloned by
# `mix wiki_race.fetch` (see `WikiRacePlatform.Deploy.GroupsFile`). They have
# no `host`/`node`: each match starts its two groups on the player VMs and
# picks their nodes then (see `WikiRacePlatform.Deploy.Match`). `slug` names
# the release folder of the group on the player VMs. Without the variable
# the manifest stays the local one below, so `check_groups/0` and its test
# never see checkouts that only exist on the platform VM.

if System.get_env("WIKI_RACE_VMS") == "true" do
  for group <- WikiRacePlatform.Deploy.GroupsFile.read!() do
    %{
      name: group.name,
      slug: group.slug,
      app: :player,
      repo: group.repo,
      tag: group.tag,
      sha: "see `git -C #{group.checkout} rev-parse HEAD`",
      path: Path.expand(group.dir, group.checkout),
      module: nil,
      host: nil,
      node: nil
    }
  end
else
  [
    %{
      name: "Local fixture",
      app: :player,
      repo: "local, player/ skeleton, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: nil
    },
    %{
      name: "player1",
      app: :player,
      repo: "local, player/ skeleton, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: :player1@player1
    },
    %{
      name: "player2",
      app: :player,
      repo: "local, player/ skeleton, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: :player2@player2
    },
    %{
      name: "Mutex Maniacs",
      app: :player,
      repo: "local test fixture, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: :mutex@platform
    },
    %{
      name: "Deadlock Debutantes",
      app: :player,
      repo: "local test fixture, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: :deadlock@platform
    },
    %{
      name: "Race Condition",
      app: :player,
      repo: "local test fixture, not a real clone",
      tag: "n/a",
      sha: "n/a",
      path: Path.expand("../player", File.cwd!()),
      module: nil,
      host: nil,
      node: :racecond@platform
    }
  ]
end
