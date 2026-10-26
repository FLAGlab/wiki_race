defmodule Mix.Tasks.WikiRace.Deploy do
  @moduledoc """
  Builds, uploads, and unpacks a group's release onto its player VM over SSH.

      mix wiki_race.deploy GROUP
      mix wiki_race.deploy GROUP --host player_vm1 --node groupa@player_vm1
      mix wiki_race.deploy --all

  HOST/NODE default to that group's `host`/`node` fields in `priv/groups.exs`;
  pass `--host`/`--node` to override or when the manifest doesn't set them.
  When neither is set and `player_hosts` is configured (the university VMs,
  see `WikiRacePlatform.Deploy.Match`), the release is built once and
  unpacked on every player VM, and each match starts it where it is needed.

  `--all` deploys every group of the manifest, one after the other. A group
  that fails does not stop the others. The failures are listed at the end.

  Streams the build/upload log to the terminal and exits non-zero on
  failure. Deployment is terminal-only, there is no web UI for it. Follow
  up with `mix wiki_race.start GROUP` once this succeeds, except on the
  university VMs, where starting a match on `/admin` starts the crawlers.
  """

  use Mix.Task

  alias WikiRacePlatform.Deploy.CliState
  alias WikiRacePlatform.Deploy.Manifest
  alias WikiRacePlatform.Deploy.Match
  alias WikiRacePlatform.Deploy.Server, as: Deploy

  @shortdoc "Deploys a group's release to its player VM over SSH"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [host: :string, node: :string, all: :boolean])

    case {opts[:all], positional} do
      {true, []} ->
        deploy_all()

      {nil, [name]} ->
        case deploy(name, opts) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("#{name}: deploy failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise(
          "usage: mix wiki_race.deploy GROUP [--host HOST --node NODE] | mix wiki_race.deploy --all"
        )
    end
  end

  defp deploy_all do
    failures =
      Enum.flat_map(Manifest.groups(), fn group ->
        Mix.shell().info("\n==> #{group.name}")

        case deploy(group.name, []) do
          :ok -> []
          {:error, reason} -> [{group.name, reason}]
        end
      end)

    case failures do
      [] ->
        Mix.shell().info("\nEvery group is deployed.")

      _ ->
        Mix.raise(
          "these groups failed to deploy:\n" <>
            Enum.map_join(failures, "\n", fn {name, reason} ->
              "  #{name}: #{inspect(reason)}"
            end)
        )
    end
  end

  defp deploy(group_name, opts) do
    group = Manifest.group!(group_name)
    targets = resolve_targets(group, opts)
    cookie = Deploy.new_cookie()

    Deploy.subscribe(group_name)

    case Deploy.deploy!(group_name, targets, Deploy, cookie) do
      :ok -> await_terminal(group_name, hd(targets), cookie)
      {:error, message} -> {:error, message}
    end
  end

  defp resolve_targets(group, opts) do
    host = opts[:host] || Map.get(group, :host)
    node = if opts[:node], do: String.to_atom(opts[:node]), else: Map.get(group, :node)

    cond do
      host && node ->
        [%{host: host, node: node}]

      host == nil and node == nil and Match.enabled?() ->
        for host <- Match.player_hosts(),
            do: %{host: host, node: Match.node_for(group, host)}

      host == nil ->
        Mix.raise(
          "no --host given and no host configured in priv/groups.exs for #{group.name}"
        )

      true ->
        Mix.raise(
          "no --node given and no node configured in priv/groups.exs for #{group.name}"
        )
    end
  end

  defp await_terminal(group_name, target, cookie) do
    receive do
      {:deploy_update, ^group_name, status, line} ->
        if line, do: Mix.shell().info(line)
        handle_status(group_name, target, cookie, status)
    after
      600_000 -> {:error, :timed_out}
    end
  end

  defp handle_status(group_name, target, cookie, :stopped) do
    CliState.put(group_name, target, cookie)

    if Match.enabled?() do
      Mix.shell().info(
        "#{group_name}: deployed to #{Enum.join(Match.player_hosts(), ", ")}."
      )
    else
      Mix.shell().info(
        "#{group_name}: deployed. Run `mix wiki_race.start #{inspect(group_name)}` next."
      )
    end
  end

  defp handle_status(_group_name, _target, _cookie, {:error, reason}) do
    {:error, reason}
  end

  defp handle_status(group_name, target, cookie, _in_progress_status) do
    await_terminal(group_name, target, cookie)
  end
end
