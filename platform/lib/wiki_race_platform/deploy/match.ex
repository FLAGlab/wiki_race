defmodule WikiRacePlatform.Deploy.Match do
  @moduledoc """
  Starts the crawlers of one match on the player VMs, right before the race.

  With `config :wiki_race_platform, :deploy, player_hosts: [...]` set, every
  group's release is already unpacked on every player VM
  (`mix wiki_race.deploy --all`). Before each match, `prepare/2` stops
  whatever runs on the player VMs and starts the groups of that match, the
  first one on the first host and the second one on the second host. A bye
  uses the first host only. Each crawler then has its player VM to itself,
  in a fresh BEAM, whatever ran there before.

  Every start gets a new random cookie (`Deploy.Server.new_cookie/0`), and
  the node of a group on a host is `<slug>@<host>`. The web node and the
  harness are the same node here (`deploy/final/wikirace server`), which
  is what `app_started?` below relies on.

  Without `player_hosts`, as in the local setup, matches use the fixed
  nodes of `priv/groups.exs` instead (`WikiRacePlatformWeb.NodeResolution`).
  """

  alias WikiRacePlatform.Deploy.GroupsFile
  alias WikiRacePlatform.Deploy.Manifest
  alias WikiRacePlatform.Deploy.Server

  @start_timeout_ms 45_000
  @app_timeout_ms 15_000
  @app_poll_ms 250

  @doc "Whether matches start their crawlers on demand, that is, whether `player_hosts` is set."
  @spec enabled?() :: boolean()
  def enabled?, do: player_hosts() != []

  @doc "The player VMs, in the order matches fill them."
  @spec player_hosts() :: [String.t()]
  def player_hosts do
    :wiki_race_platform
    |> Application.get_env(:deploy, [])
    |> Keyword.get(:player_hosts, [])
  end

  @doc "The node `group` runs as on `host`."
  @spec node_for(map(), String.t()) :: node()
  def node_for(group, host), do: :"#{GroupsFile.slug(group.name)}@#{host}"

  @doc """
  Stops everything on the player VMs and starts the groups of `fixture`.
  Returns the `%{name => node}` mapping `Tournament.Server.start_next!/2`
  needs. Takes a few seconds.

  Options: `:server` (the `Deploy.Server`), `:hosts` (default
  `player_hosts/0`), `:app_started?`, a `(node, app -> boolean)` that
  tells whether the group's application has started on its node, and
  `:app_timeout_ms`, how long to wait for that.
  """
  @spec prepare(WikiRacePlatform.Tournament.Fixtures.fixture(), keyword()) ::
          {:ok, %{String.t() => node()}} | {:error, String.t()}
  def prepare(fixture, opts \\ []) do
    server = Keyword.get(opts, :server, Server)
    hosts = Keyword.get(opts, :hosts, player_hosts())

    app_check = {
      Keyword.get(opts, :app_started?, &app_started?/2),
      Keyword.get(opts, :app_timeout_ms, @app_timeout_ms)
    }

    names = participants(fixture)

    with :ok <- check_hosts(names, hosts),
         :ok <- clear_hosts(hosts, server) do
      names
      |> Enum.zip(hosts)
      |> Task.async_stream(&start_on(&1, server, app_check), timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)
      |> collect()
    end
  end

  defp participants({:bye, name}), do: [name]
  defp participants({a, b}), do: [a, b]

  defp check_hosts(names, hosts) when length(names) <= length(hosts), do: :ok

  defp check_hosts(names, hosts) do
    {:error,
     "#{length(names)} groups to start, but only #{length(hosts)} player VMs configured"}
  end

  defp clear_hosts(hosts, server) do
    hosts
    |> Task.async_stream(&{&1, Server.clear_host(&1, server)}, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, {_host, :ok}} ->
        []

      {:ok, {host, {:error, reason}}} ->
        ["could not stop the crawler on #{host}: #{inspect(reason)}"]
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "; ")}
    end
  end

  defp start_on({name, host}, server, {app_started?, app_timeout_ms}) do
    group = Manifest.group!(name)
    node = node_for(group, host)

    # Subscribed before start!, so the :running update cannot be missed.
    Server.subscribe(name)
    :ok = Server.reattach!(name, %{host: host, node: node}, Server.new_cookie(), server)

    with :ok <- Server.start!(name, server),
         :ok <- await_running(name),
         :ok <- await_app(node, group.app, app_started?, app_timeout_ms) do
      {:ok, {name, node}}
    else
      {:error, reason} when is_binary(reason) -> {:error, "#{name} on #{host}: #{reason}"}
      {:error, reason} -> {:error, "#{name} on #{host}: #{inspect(reason)}"}
    end
  end

  defp await_running(name) do
    receive do
      {:deploy_update, ^name, :running, _line} -> :ok
      {:deploy_update, ^name, {:error, reason}, _line} -> {:error, reason}
      {:deploy_update, ^name, _other, _line} -> await_running(name)
    after
      @start_timeout_ms -> {:error, :start_timed_out}
    end
  end

  # A node accepts connections as soon as distribution is up, which can be
  # before its applications have started. The harness looks for the
  # crawler module right away, so wait until the group's app is running.
  defp await_app(_node, app, _app_started?, timeout_ms) when timeout_ms <= 0 do
    {:error, "#{app} did not start"}
  end

  defp await_app(node, app, app_started?, timeout_ms) do
    if app_started?.(node, app) do
      :ok
    else
      Process.sleep(@app_poll_ms)
      await_app(node, app, app_started?, timeout_ms - @app_poll_ms)
    end
  end

  defp app_started?(node, app) do
    case :rpc.call(node, Application, :started_applications, [], 2_000) do
      apps when is_list(apps) -> List.keymember?(apps, app, 0)
      {:badrpc, _reason} -> false
    end
  end

  defp collect(results) do
    case for({:error, message} <- results, do: message) do
      [] -> {:ok, Map.new(for {:ok, pair} <- results, do: pair)}
      errors -> {:error, Enum.join(errors, "; ")}
    end
  end
end
