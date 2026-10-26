# Running a tournament

This file is for the professor. Students only need `RUNNING.md`. Run every command from
the repo root unless a step says otherwise.

## Article pairs

Races do not use random articles. Two random articles may be many hops apart or not
connected at all, so the time of a race would be unpredictable. Every race uses a pair
from the pool in `platform/priv/article_pairs.exs`. The rounds of a tournament use the
sequence of pairs in `round_pairs` in `platform/config/config.exs`. The list on `/admin`
changes the pair for the current round only.

After you edit the pool, check it against the running Kiwix server:

```
cd platform && iex -S mix
```

```elixir
WikiRacePlatform.Articles.check_pairs()
```

## Deploying a release

Deploying builds the `mix release` of a group, copies it to a player VM, starts it, and
checks that it joins the cluster. The platform uses the `:ssh` and `:ssh_sftp` modules of
Erlang. It never calls an `ssh` binary. Deployment runs from the terminal, through
`mix wiki_race.deploy`, `mix wiki_race.start` and `mix wiki_race.stop`. There is no web
page for it.

Deploy each group once, before the tournament. Each release then stays running and
connected for every match it plays. During the tournament, `/admin` finds the node of
each group by its name in `platform/priv/groups.exs`. Nothing is deployed again.

Groups are listed in `platform/priv/groups.exs`. It ships with an entry named
"Local fixture" that points at the `player/` folder of this repo. It is enough to test
the whole deploy without a real group.

This section uses the simulated player VMs. For the university VMs, see "Competition day
on the university VMs" below. Docker Compose provides two simulated ones, `player_vm1` and
`player_vm2`. They run a real `sshd`, so the SSH traffic is real. They do not start with
`make up`. To start one:

```
make deploy-keys deploy-images
docker compose up -d player_vm1
```

`make deploy-keys` creates a dev keypair in `deploy/keys/`, which is never committed. The
platform logs in with it. The simulated VM reads the public key at start, so the key must
exist before the container starts. `make deploy-images` builds the image of the
simulated VMs.

The release is built with `docker compose run`, so the platform that deploys must run on
the host, not inside its container (see "Running without Docker Compose" below, and the
note on long node names). Then, from `platform/`, deploy and start the release:

```
mix wiki_race.deploy "Local fixture" --host HOST --node NODE
mix wiki_race.start "Local fixture"
```

`HOST` is the IP of the VM container and `NODE` is the node name of the release, with
that IP, for example `groupa@172.20.0.3`. Both values default to the `host` and `node`
fields of the group in `platform/priv/groups.exs`.

`mix wiki_race.deploy` prints the build log. When it reports the group as deployed, the
release is on the VM but not running. `mix wiki_race.start` starts it and joins it to the
cluster. `mix wiki_race.stop` stops it.

**Long node names.** The `platform`, `player1` and `player2` containers use short names
(`--sname`). A deployed release uses long names (`--name`), because a real VM is reached
by IP or by hostname. Erlang requires both sides of a connection to use the same kind of
name. To drive a deploy from a platform that runs on the host, start it with a long name:

```
cd platform && elixir --name platform@127.0.0.1 --cookie wikirace -S mix phx.server
```

**Resource limits.** A release runs as the unprivileged `deploy` user
(`deploy/vm/Dockerfile`). `mem_limit` and `cpus` in `docker-compose.yml` limit each
simulated VM, with the same values on both sides. The limits stop a runaway process. They
do not limit the parallelism being graded. On a real VM, the equivalent is a systemd unit
that runs the release as its own user, with the same `MemoryMax=` and `CPUQuota=` on
both sides. This unit is not built yet.

`make test-deploy` runs the integration test against `player_vm1`: a real release build,
a real SSH session, and a real cluster join. See
`platform/test/wiki_race_platform/deploy/integration_test.exs`. Plain `mix test` does not
need Docker, because tests tagged `:integration` are excluded by default.

## Competition day on the university VMs

The scripts in `deploy/final/` set up four Ubuntu 26.04 VMs for a tournament. Every
script needs sudo, except `wikirace`. The VMs do not use Docker. Docker Compose is only the
local simulation of this setup.

Every group's release is unpacked on both player VMs before the tournament. Each match on
`/admin` then stops whatever runs on the player VMs, starts its first group on player VM 1
and its second group on player VM 2, and starts the race once both have joined. A bye
uses player VM 1 only. So each crawler has its VM to itself, in a fresh BEAM, and nothing
is built or copied between matches.

1. On each VM, clone this repo. Copy `deploy/final/final.env.example` to
   `deploy/final/final.env` and fill it in: the IPs of the four VMs, the port of the
   platform and a cookie for it. All four VMs need the same file. It is never committed.
2. On the Wikipedia VM, run `sudo deploy/final/setup-wikipedia-vm.sh`. It installs the
   static build of `kiwix-serve` in `/opt/wikirace`, downloads the 52 GB snapshot and
   runs Kiwix on port 8080 as the systemd service `wikirace-kiwix`, started on boot. The
   download takes a while, so run it inside `tmux`. To skip the download, copy the
   snapshot to `.data/zim/wikipedia_en_all_nopic.zim` first.
3. On the platform VM, run `sudo deploy/final/setup-platform-vm.sh`. It installs Erlang
   and Elixir (the versions of `.tool-versions`, in `/opt/wikirace`) and the deploy key,
   and runs `mix setup`. The script prints a public key at the end.
4. On each player VM, run `sudo deploy/final/setup-player-vm.sh "<that public key>"`. It
   creates the `deploy` user and `/home/deploy/releases`, as in `deploy/vm/Dockerfile`.
5. On the platform VM, copy `deploy/final/groups.txt.example` to
   `deploy/final/groups.txt` and list the groups, one per line:
   `name | public repository | tag | folder of the player`. The folder defaults to
   `player`. Write `.` when `mix.exs` is at the root of the repository. The names are the
   roster of the tournament.
6. On the platform VM, as your normal user:

   ```
   deploy/final/wikirace fetch          # clones every group at its tag, prints each commit
   deploy/final/wikirace check          # Kiwix, the groups, SSH to both player VMs
   deploy/final/wikirace deploy         # builds every release, copies it to both player VMs
   deploy/final/wikirace server         # in tmux: the platform, on PLATFORM_PORT
   ```

   `deploy` takes one to two minutes per group, so run it the day before. A group that
   fails does not stop the others, and the failures are listed at the end.
   `wikirace deploy "<name>"` builds and copies one group again.
7. On each player VM, run `sudo deploy/final/setup-player-vm.sh --lockdown`. A firewall
   then allows outgoing traffic only to Kiwix and to the platform, like the internal
   networks of `docker-compose.yml`. A crawler cannot reach the internet or the other
   player VM. `wikirace check` shows `internet from player: blocked`.
8. Open `http://<PLATFORM_IP>:<PLATFORM_PORT>/admin`. Each click on the start button
   starts the crawlers of the next match, which takes a few seconds, and then the race.
   `PLATFORM_PORT` in `final.env` defaults to 4000. The university network may block it
   between the classroom and the VMs, so use a port it lets through, such as 8080
   (`nc -zv <PLATFORM_IP> <port>` from a classroom machine answers `Connection refused`,
   not `timed out`, for an open port with nothing listening).
9. At the end, `deploy/final/wikirace stop` stops every crawler on both player VMs.

The name `kiwix1` points at the Wikipedia VM on the platform VM and on the player VMs, so
the crawlers get the same URLs as in the local setup. `wikirace` runs the platform with
`WIKI_RACE_VMS=true`. With it, `config/runtime.exs` takes the roster from `groups.txt`
and keeps the Swiss tournament of `config/config.exs` (4 rounds, with its
`round_pairs`), and `priv/groups.exs` holds only the groups of `groups.txt`.

**Releases without Docker.** Locally, `Deploy.Release` builds a release in the
`release_builder` container, so that it runs on the simulated VMs. On the university VMs,
`WIKI_RACE_VMS=true` also sets `config :wiki_race_platform, :deploy, builder: :native`.
The platform VM then builds the release in the checkout of the group, with its own
Erlang and Elixir. The release includes that Erlang runtime. All four VMs run the same
Ubuntu, so it runs on the player VMs.

**One folder per group.** Every group ships the app `player`, so a release unpacks into
`/home/deploy/releases/<slug>`, where the slug is the name of the group in lowercase
with `_` for spaces. The node of a group is `<slug>@<player VM IP>`, and every start
gets a new random cookie.

**After a platform restart.** Nothing to do. The next match stops whatever still runs on
the player VMs and starts its own crawlers.

**Distinct cookies and `:global`.** Each player has its own cookie, so the two players
never connect to each other. `:global` sees this as an overlapping partition, and with
its default settings it disconnects one player as soon as the other one joins. The
deploy therefore starts every release with
`ERL_AFLAGS="-kernel prevent_overlapping_partitions false ..."`, and `wikirace` starts
the platform with the same flags. The flags also fix the distribution port of the player
to the range 9100 to 9109, which the firewall opens to the platform. The groups do not
change anything. This applies to any platform node that connects to two deployed
players, including the simulated VMs above.

**Results.** Finished races are saved in `platform/priv/data/results.terms`. "Restart
tournament" on `/admin` starts the tournament again.

## Security

The simulated VMs are already locked down in `docker-compose.yml`:

- The root filesystem is read only. Only `/tmp`, `/run` and `/home/deploy/releases` are
  writable. The release runs from `/home/deploy/releases`, so only that folder allows
  running programs.
- `player1_net` and `player2_net` have no internet access. Each VM is on its own network,
  so `player_vm1` cannot reach `player_vm2`. Both can reach `kiwix1` and `platform`.

To check this by hand:

```
docker exec wikirace-player_vm1-1 sh -c 'touch /etc/x'            # fails, read only
docker exec wikirace-player_vm1-1 elixir -e ':gen_tcp.connect(~c"1.1.1.1", 80, [], 3000) |> IO.inspect()'  # fails, no internet
```

Three more protections exist in the code. They are tested with two separate Erlang
nodes, but they are not enabled by `make up`, because the `player1`/`player2` setup would
have to change too.

**Split harness.** The web part of the platform never connects to a player itself. It
asks the node in `:harness_node` to do it, with `:rpc.call/4`. Set `WEB_NODE` and
`HARNESS_NODE` to two different nodes to split them. Both default to the current node.
Race results are always stored on the node in `:web_node`.

**One cookie per release.** This one is always on. Every deploy creates a new random
cookie for that release. Only the harness node uses it, and only for that release. A
player never learns any other cookie.

**TLS distribution.**

```
make dist-certs
```

This creates a dev CA and one certificate for each role (`web`, `harness`, `player`) in
`deploy/certs/`. A node without a certificate signed by this CA cannot join the cluster.
To enable it:

- Start `web` and `harness` with `-proto_dist inet_tls -ssl_dist_optfile
  deploy/certs/<role>.conf` in `ELIXIR_ERL_OPTIONS`.
- Set `config :wiki_race_platform, :deploy, tls: true` in `platform/config/`, plus
  `:tls_certs_dir` if the certificates are not in `../deploy/certs`. Each deploy then
  uploads the player certificate, its key, the CA certificate and a `RELEASE_VM_ARGS`
  file, so the release also starts with TLS. The groups do not change anything.

The certificates are valid only for the hostnames and IPs in `deploy/certs/san.cnf`. Add
the real player VM hostnames and generate them again before using real VMs.

## Environment variables

| Variable             | Default                  | What it does                                     |
| -------------------- | ------------------------ | ------------------------------------------------ |
| `KIWIX_BASE_URL`     | `http://localhost:8080`  | Address of Kiwix                                 |
| `KIWIX_BOOK`         | `wikipedia_en_all_nopic` | Snapshot to read                                 |
| `START_HARNESS`      | `true`                   | `false` on a node that only runs the web part    |
| `START_WEB`          | `true`                   | `false` on a node that only runs the harness     |
| `WEB_NODE`           | this node                | Node that stores results and deploys, if split   |
| `HARNESS_NODE`       | this node                | Node that runs the races, if split               |
| `PORT`               | `4000`                   | HTTP port                                        |
| `WIKI_RACE_DATA_DIR` | `priv/data`              | Folder where finished race results are saved     |

`docker-compose.yml` sets these for the containers. `KIWIX_BOOK` defaults to
`wikipedia_en_top_nopic` there, and to the full snapshot everywhere else.

## Running without Docker Compose

Useful to debug the platform or a player node directly. You need Elixir and Erlang
installed (see `.tool-versions`).

Serve the snapshot with Kiwix (from the repo root, and adjust the file name to your
snapshot):

```
docker run -d --name wikirace-kiwix -p 8080:8080 \
  -v "$(pwd)/.data/zim:/data:ro" \
  ghcr.io/kiwix/kiwix-serve:latest /data/wikipedia_en_top_nopic.zim
```

`curl -sI http://localhost:8080/` should return 200.

Start the platform:

```
cd platform
mix setup
KIWIX_BOOK=wikipedia_en_top_nopic elixir --sname platform --cookie wikirace -S mix phx.server
```

Start a player node from `player/`, and let `bin/connect.exs` connect it to the
platform. `hostname -s` gives the short name of your machine:

```
cd player
PLATFORM_NODE=platform@$(hostname -s) \
  elixir --sname player1 --cookie wikirace -S mix run --no-halt bin/connect.exs
```

Start `player2` the same way in another terminal. `/admin` finds the players through the
`node` field in `platform/priv/groups.exs`, which is `player1@player1` and
`player2@player2` for Docker Compose. Change it to `player1@<hostname>` and
`player2@<hostname>` for this setup.
