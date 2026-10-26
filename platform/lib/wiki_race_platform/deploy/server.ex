defmodule WikiRacePlatform.Deploy.Server do
  @moduledoc """
  Deploys, starts, stops, and reports on each group's release.

  Every long operation (`deploy!/3`, `start!/2`, `stop!/2`) runs in a `Task`
  under `Deploy.TaskSupervisor` and reports back to this GenServer, which
  updates the group's status and broadcasts on `Phoenix.PubSub` topic
  `"deploy:\#{group_name}"`. Use `subscribe/1` to stream that topic in the
  admin UI. The client calls themselves return immediately once the
  operation is accepted; watch the topic (or poll `status/2`) for progress.

  Like `Tournament.Server`'s `:store`/`:dispatcher` options, every external
  seam here is injectable for tests: `:transport` (default
  `Deploy.Transport.SSH`), `:connect` (default `Node.connect/1`), and
  `:connected_nodes` (default `Race.connected_nodes/0`).

  This node (`web`) builds and ships a release over SSH, but never opens
  the actual distribution link to a player itself. Only the harness node
  does that, so `web` holds no capability worth exploiting if compromised.
  `join/6` runs wherever `:harness_node` points (itself, in the default
  single-node setup), reached over `:rpc.call/4` using this app's own
  internal cookie, never the per-player cookie a deploy hands to a player
  release.

  Each deploy also gets its own random distribution cookie (`deploy!/3`
  generates it, `run_start/9` hands it to the release as `RELEASE_COOKIE`),
  never the shared static cookie this app itself runs under. The harness
  sets that cookie on the specific player node it's about to connect to
  (`Node.set_cookie/2`, a per-node override; its own default cookie, used
  for everything else, is untouched) right before connecting. A player
  never learns any cookie but its own, so it can reach neither `web` nor
  another player's node, even one it could otherwise route to.
  """

  use GenServer

  alias WikiRacePlatform.Deploy.Release
  alias WikiRacePlatform.Deploy.Transport

  @type target :: %{host: String.t(), node: node()}
  @type status ::
          :idle
          | :building
          | :uploading
          | :starting
          | :running
          | :stopped
          | {:error, term()}

  defstruct groups: %{},
            transport: Transport.SSH,
            release_builder: Release,
            task_supervisor: WikiRacePlatform.Deploy.TaskSupervisor,
            connect: &Node.connect/1,
            connected_nodes: &WikiRacePlatform.Race.connected_nodes/0,
            harness_node: nil,
            join_timeout_ms: 10_000,
            join_poll_ms: 250

  @remote_dir "/home/deploy/releases"

  # Kernel flags for every player release, passed in `ERL_AFLAGS` so the
  # group's own code and vm.args stay untouched. Each player has its own
  # cookie, so two players never connect to each other. With the default
  # `prevent_overlapping_partitions true`, `:global` treats that as an
  # overlapping partition and disconnects one player from the harness as
  # soon as the second one joins. The listen range pins the distribution
  # port, so the player VM firewall only needs to open 4369 and this range
  # to the platform (see deploy/final/).
  @player_erl_flags "-kernel prevent_overlapping_partitions false " <>
                      "inet_dist_listen_min 9100 inet_dist_listen_max 9109"

  # Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Builds, uploads, and unpacks `group_name`'s release onto `target`. Returns
  immediately; watch `subscribe/1`.

  `cookie` comes after `server`, so every existing 3-arg call (`deploy!(name,
  target, server)`) keeps meaning what it always meant. It lets a caller
  that needs to reach this same deploy again from a different process (the
  terminal-only `mix wiki_race.*` tasks, one BEAM per invocation, unlike
  the admin LiveView's single long-lived one) supply its own random cookie
  up front, instead of never learning the one generated internally. See
  `reattach!/4`. `nil` (the default) generates one internally, exactly as
  before.
  """
  @spec deploy!(String.t(), target(), GenServer.server(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def deploy!(group_name, target, server \\ __MODULE__, cookie \\ nil) do
    GenServer.call(server, {:deploy, group_name, target, cookie})
  end

  @doc """
  Seeds this server's state for `group_name` with a previously known
  `target`/`cookie`, without re-running the deploy pipeline.

  For terminal use: `mix wiki_race.start`/`.stop` are each their own
  short-lived process, so they reattach to the target/cookie a prior
  `mix wiki_race.deploy` persisted (see `WikiRacePlatform.Deploy.CliState`)
  before calling `start!/2`/`stop!/2`, which otherwise assume they're
  running right after `deploy!/4` in the same process.
  """
  @spec reattach!(String.t(), target(), String.t(), GenServer.server()) :: :ok
  def reattach!(group_name, target, cookie, server \\ __MODULE__) do
    GenServer.call(server, {:reattach, group_name, target, cookie})
  end

  @doc "Starts the already-deployed release as a daemon and waits for it to join the cluster."
  @spec start!(String.t(), GenServer.server()) :: :ok | {:error, String.t()}
  def start!(group_name, server \\ __MODULE__) do
    GenServer.call(server, {:start, group_name})
  end

  @doc "Stops the running release."
  @spec stop!(String.t(), GenServer.server()) :: :ok | {:error, String.t()}
  def stop!(group_name, server \\ __MODULE__) do
    GenServer.call(server, {:stop, group_name})
  end

  @doc "This group's last known status and whether its target node is currently connected."
  @spec status(String.t(), GenServer.server()) :: %{
          deploy: status(),
          connected: boolean()
        }
  def status(group_name, server \\ __MODULE__) do
    GenServer.call(server, {:status, group_name})
  end

  @doc "Subscribes the calling process to `{:deploy_update, group_name, status, log_line | nil}`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(group_name) do
    Phoenix.PubSub.subscribe(WikiRacePlatform.PubSub, topic(group_name))
  end

  @doc false
  def topic(group_name), do: "deploy:#{group_name}"

  @doc """
  Sets `cookie` on `node` (a per-node override; this node's own default
  cookie is untouched) and waits for it to join the cluster. This is the
  one operation restricted to running only on the harness node, called via
  `:rpc.call/4` from `run_start/9` instead of executed locally on `web`.
  Public so RPC (and, in a single-node setup, ordinary local calls) can
  reach it.
  """
  @spec join(node(), String.t(), function(), function(), integer(), integer()) ::
          :ok | {:error, term()}
  def join(node, cookie, connect, connected_nodes, join_timeout_ms, join_poll_ms) do
    # `Node.set_cookie/2` raises outright on a non-distributed node (this
    # app's own fast test suite, not started with --name). There is
    # nothing to set on a node that can't have peers in the first place.
    if Node.alive?(), do: Node.set_cookie(node, String.to_atom(cookie))
    wait_for_join(node, connect, connected_nodes, join_timeout_ms, join_poll_ms)
  end

  # Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      transport: Keyword.get(opts, :transport, Transport.SSH),
      release_builder: Keyword.get(opts, :release_builder, Release),
      task_supervisor:
        Keyword.get(opts, :task_supervisor, WikiRacePlatform.Deploy.TaskSupervisor),
      connect: Keyword.get(opts, :connect, &Node.connect/1),
      connected_nodes:
        Keyword.get(opts, :connected_nodes, &WikiRacePlatform.Race.connected_nodes/0),
      harness_node:
        Keyword.get(
          opts,
          :harness_node,
          Application.get_env(:wiki_race_platform, :harness_node, node())
        ),
      join_timeout_ms: Keyword.get(opts, :join_timeout_ms, 10_000),
      join_poll_ms: Keyword.get(opts, :join_poll_ms, 250)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:deploy, group_name, target, given_cookie}, _from, state) do
    case busy?(state, group_name) do
      true ->
        {:reply, {:error, "#{group_name} is already busy"}, state}

      false ->
        server = self()
        group = WikiRacePlatform.Deploy.Manifest.group!(group_name)
        transport = state.transport
        release_builder = state.release_builder
        cookie = given_cookie || random_cookie()

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          run_deploy(server, transport, release_builder, group, target)
        end)

        {:reply, :ok,
         put_status(state, group_name, :building, target: target, cookie: cookie, log: [])}
    end
  end

  def handle_call({:reattach, group_name, target, cookie}, _from, state) do
    {:reply, :ok, put_status(state, group_name, :stopped, target: target, cookie: cookie)}
  end

  def handle_call({:start, group_name}, _from, state) do
    case Map.get(state.groups, group_name) do
      %{target: target, cookie: cookie} when not is_nil(target) ->
        server = self()
        group = WikiRacePlatform.Deploy.Manifest.group!(group_name)
        transport = state.transport
        connect = state.connect
        connected_nodes = state.connected_nodes
        harness_node = state.harness_node
        join_timeout_ms = state.join_timeout_ms
        join_poll_ms = state.join_poll_ms

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          run_start(
            server,
            transport,
            group,
            target,
            cookie,
            harness_node,
            connect,
            connected_nodes,
            join_timeout_ms,
            join_poll_ms
          )
        end)

        {:reply, :ok, put_status(state, group_name, :starting)}

      _ ->
        {:reply, {:error, "#{group_name} has no deploy target yet"}, state}
    end
  end

  def handle_call({:stop, group_name}, _from, state) do
    case Map.get(state.groups, group_name) do
      %{target: target, cookie: cookie} when not is_nil(target) ->
        server = self()
        group = WikiRacePlatform.Deploy.Manifest.group!(group_name)
        transport = state.transport

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          run_stop(server, transport, group, target, cookie)
        end)

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, "#{group_name} has no deploy target yet"}, state}
    end
  end

  def handle_call({:status, group_name}, _from, state) do
    entry = Map.get(state.groups, group_name, %{status: :idle, target: nil})
    connected = entry.target != nil and entry.target.node in state.connected_nodes.()
    {:reply, %{deploy: entry.status, connected: connected}, state}
  end

  @impl true
  def handle_cast({:log, group_name, line}, state) do
    broadcast(group_name, current_status(state, group_name), line)
    {:noreply, update_log(state, group_name, line)}
  end

  def handle_cast({:status, group_name, new_status}, state) do
    broadcast(group_name, new_status, nil)
    {:noreply, put_status(state, group_name, new_status)}
  end

  defp busy?(state, group_name) do
    case Map.get(state.groups, group_name) do
      %{status: status} -> status in [:building, :uploading, :starting]
      nil -> false
    end
  end

  defp current_status(state, group_name) do
    case Map.get(state.groups, group_name) do
      %{status: status} -> status
      nil -> :idle
    end
  end

  defp put_status(state, group_name, status, extra \\ []) do
    entry =
      state.groups
      |> Map.get(group_name, %{status: :idle, target: nil, cookie: nil, log: []})
      |> Map.put(:status, status)
      |> Map.merge(Map.new(extra))

    %{state | groups: Map.put(state.groups, group_name, entry)}
  end

  defp update_log(state, group_name, line) do
    entry =
      Map.get(state.groups, group_name, %{
        status: :idle,
        target: nil,
        cookie: nil,
        log: []
      })

    %{
      state
      | groups: Map.put(state.groups, group_name, %{entry | log: [line | entry.log]})
    }
  end

  defp broadcast(group_name, status, line) do
    Phoenix.PubSub.broadcast(
      WikiRacePlatform.PubSub,
      topic(group_name),
      {:deploy_update, group_name, status, line}
    )
  end

  # Deploy pipeline, running inside a Task. Every step reports back to the
  # GenServer by name/pid (`server`) and never touches its state directly.

  defp run_deploy(server, transport, release_builder, group, target) do
    on_output = fn line -> GenServer.cast(server, {:log, group.name, line}) end

    result =
      with {:ok, tarball} <- release_builder.build(group, on_output),
           :ok <- GenServer.cast(server, {:status, group.name, :uploading}),
           ssh_opts = ssh_opts(),
           {:ok, conn} <- transport.connect(target.host, ssh_opts),
           :ok <- transport.exec(conn, "mkdir -p #{@remote_dir}") |> ok_or_error(),
           remote_tarball = "#{@remote_dir}/#{group.app}.tar.gz",
           :ok <- transport.upload(conn, tarball, remote_tarball),
           unpack = "tar -xzf #{remote_tarball} -C #{@remote_dir}",
           :ok <- transport.exec(conn, unpack) |> ok_or_error(),
           :ok <- transport.close(conn) do
        File.rm(tarball)
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok -> GenServer.cast(server, {:status, group.name, :stopped})
      {:error, reason} -> GenServer.cast(server, {:status, group.name, {:error, reason}})
    end
  end

  defp run_start(
         server,
         transport,
         group,
         target,
         cookie,
         harness_node,
         connect,
         connected_nodes,
         join_timeout_ms,
         join_poll_ms
       ) do
    remote_app_dir = "#{@remote_dir}/#{group.app}"

    result =
      with {:ok, conn} <- transport.connect(target.host, ssh_opts()),
           {:ok, vm_args_env} <- provision_tls(transport, conn),
           # Long name, not short. A real player VM is identified by an IP
           # or FQDN, not a docker-internal service alias, so this platform
           # node has to be started the same way (`--name`, not `--sname`)
           # for `connect.(target.node)` below to succeed. This is distinct
           # from the existing docker-compose player1/player2 dev-parity
           # flow, which stays on `--sname` untouched: that is a separate
           # loop for iterating on a crawler, not this deploy pipeline.
           #
           # RELEASE_COOKIE is this deploy's own random cookie (see
           # `deploy!/3`), never this app's own. A player only ever learns
           # its own cookie.
           start_cmd =
             "cd #{remote_app_dir} && #{vm_args_env}" <>
               "ERL_AFLAGS='#{@player_erl_flags}' " <>
               "RELEASE_COOKIE=#{cookie} RELEASE_NODE=#{target.node} " <>
               "RELEASE_DISTRIBUTION=name START_HARNESS=false bin/#{group.app} daemon",
           :ok <- transport.exec(conn, start_cmd) |> ok_or_error(),
           :ok <- transport.close(conn) do
        # Only the harness node ever opens the actual distribution link to
        # a player. `web` (this node, unless they're the same) asks it to
        # over an internal :rpc call, instead of connecting itself.
        case :rpc.call(harness_node, __MODULE__, :join, [
               target.node,
               cookie,
               connect,
               connected_nodes,
               join_timeout_ms,
               join_poll_ms
             ]) do
          {:badrpc, reason} -> {:error, {:harness_unreachable, reason}}
          result -> result
        end
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok -> GenServer.cast(server, {:status, group.name, :running})
      {:error, reason} -> GenServer.cast(server, {:status, group.name, {:error, reason}})
    end
  end

  defp run_stop(server, transport, group, target, cookie) do
    remote_app_dir = "#{@remote_dir}/#{group.app}"

    # `bin/<app> stop` opens its own short-lived node to RPC the running one
    # into stopping. That ephemeral node needs the same cookie/distribution
    # mode `run_start/10` used, or it can't find it either.
    stop_cmd =
      "cd #{remote_app_dir} && " <>
        "RELEASE_COOKIE=#{cookie} RELEASE_NODE=#{target.node} " <>
        "RELEASE_DISTRIBUTION=name bin/#{group.app} stop"

    result =
      with {:ok, conn} <- transport.connect(target.host, ssh_opts()),
           :ok <- transport.exec(conn, stop_cmd) |> ok_or_error(),
           :ok <- transport.close(conn) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok -> GenServer.cast(server, {:status, group.name, :stopped})
      {:error, reason} -> GenServer.cast(server, {:status, group.name, {:error, reason}})
    end
  end

  # The remote release has just been asked to daemonize over SSH, which
  # returns as soon as the process detaches, well before its BEAM has
  # actually finished booting and registered with epmd. A single
  # `connect.()` right after that would almost always fire too early and
  # fail, so each poll retries the connect instead of connecting once and
  # only watching `Node.list()`.
  defp wait_for_join(_node, _connect, _connected_nodes, timeout_ms, _poll_ms)
       when timeout_ms <= 0 do
    {:error, :did_not_join}
  end

  defp wait_for_join(node, connect, connected_nodes, timeout_ms, poll_ms) do
    connect.(node)

    if node in connected_nodes.() do
      :ok
    else
      Process.sleep(poll_ms)
      wait_for_join(node, connect, connected_nodes, timeout_ms - poll_ms, poll_ms)
    end
  end

  # When TLS distribution is configured, uploads the player role's
  # cert/key/CA cert plus a freshly written ssl_dist_optfile pointing at
  # their remote paths (the ones baked into `make dist-certs`'s local .conf
  # are dev-machine paths, meaningless on the player VM), and returns the
  # `RELEASE_VM_ARGS=...` prefix `run_start/10`'s start command needs. A
  # no-op (empty prefix) when TLS isn't configured: a node started without
  # it just uses plain distribution, exactly as before this existed.
  defp provision_tls(transport, conn) do
    config = Application.get_env(:wiki_race_platform, :deploy, [])

    if Keyword.get(config, :tls, false) do
      certs_dir =
        config
        |> Keyword.get(:tls_certs_dir, "../deploy/certs")
        |> Path.expand(File.cwd!())

      remote_tls_dir = "#{@remote_dir}/tls"
      remote_optfile = "#{remote_tls_dir}/player.conf"
      remote_vm_args = "#{remote_tls_dir}/vm.args.extra"

      optfile_contents = """
      [
        {server, [
          {certfile, "#{remote_tls_dir}/player.pem"},
          {keyfile, "#{remote_tls_dir}/player.key"},
          {cacertfile, "#{remote_tls_dir}/ca.pem"},
          {verify, verify_peer},
          {fail_if_no_peer_cert, true}
        ]},
        {client, [
          {certfile, "#{remote_tls_dir}/player.pem"},
          {keyfile, "#{remote_tls_dir}/player.key"},
          {cacertfile, "#{remote_tls_dir}/ca.pem"},
          {verify, verify_peer}
        ]}
      ].
      """

      vm_args_contents = "-proto_dist inet_tls\n-ssl_dist_optfile #{remote_optfile}\n"

      with :ok <- transport.exec(conn, "mkdir -p #{remote_tls_dir}") |> ok_or_error(),
           :ok <- upload_string(transport, conn, optfile_contents, remote_optfile),
           :ok <- upload_string(transport, conn, vm_args_contents, remote_vm_args),
           :ok <-
             transport.upload(
               conn,
               Path.join(certs_dir, "player.pem"),
               "#{remote_tls_dir}/player.pem"
             ),
           :ok <-
             transport.upload(
               conn,
               Path.join(certs_dir, "player.key"),
               "#{remote_tls_dir}/player.key"
             ),
           :ok <-
             transport.upload(
               conn,
               Path.join(certs_dir, "ca.pem"),
               "#{remote_tls_dir}/ca.pem"
             ) do
        {:ok, "RELEASE_VM_ARGS=#{remote_vm_args} "}
      end
    else
      {:ok, ""}
    end
  end

  defp upload_string(transport, conn, contents, remote_path) do
    local_path =
      Path.join(System.tmp_dir!(), "deploy_tls_#{System.unique_integer([:positive])}")

    File.write!(local_path, contents)
    result = transport.upload(conn, local_path, remote_path)
    File.rm(local_path)
    result
  end

  # A fresh secret per deploy, known only to this specific player release
  # and the harness node that connects to it. Never this app's own cookie,
  # and never shared with any other player's deploy.
  defp random_cookie, do: :crypto.strong_rand_bytes(16) |> Base.encode16()

  defp ok_or_error({:ok, _output, 0}), do: :ok
  defp ok_or_error({:ok, output, status}), do: {:error, "exit #{status}: #{output}"}
  defp ok_or_error({:error, reason}), do: {:error, reason}

  defp ssh_opts do
    config = Application.get_env(:wiki_race_platform, :deploy, [])

    [
      user: Keyword.get(config, :ssh_user, "deploy"),
      user_dir:
        config
        |> Keyword.get(:ssh_user_dir, "../deploy/keys")
        |> Path.expand(File.cwd!())
    ]
  end
end
