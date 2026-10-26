defmodule Mix.Tasks.WikiRace.Connect do
  @moduledoc """
  Reconnects the harness to a group's release that is already running.

      mix wiki_race.connect GROUP

  A running release never connects back by itself. Only the harness opens
  the link, with the cookie `mix wiki_race.deploy` recorded (see
  `WikiRacePlatform.Deploy.CliState`). After the platform restarts, its
  links to the players and their cookies are gone, and
  `mix wiki_race.start` cannot help, because the node name on the player
  VM is still taken. This task asks the harness node to join the player
  again, without touching the release.

  Like `.start`, it must run on a distributed node with `HARNESS_NODE`
  pointing at the running platform (see `deploy/final/wikirace`).
  """

  use Mix.Task

  alias WikiRacePlatform.Deploy.CliState
  alias WikiRacePlatform.Deploy.Server, as: Deploy

  @shortdoc "Reconnects the harness to a group's running release"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    group_name =
      case args do
        [name] -> name
        _ -> Mix.raise("usage: mix wiki_race.connect GROUP")
      end

    case CliState.fetch(group_name) do
      {:ok, %{target: target, cookie: cookie}} ->
        harness_node = Application.get_env(:wiki_race_platform, :harness_node, node())

        case :rpc.call(harness_node, Deploy, :join, [
               target.node,
               cookie,
               &Node.connect/1,
               &WikiRacePlatform.Race.connected_nodes/0,
               10_000,
               250
             ]) do
          :ok ->
            Mix.shell().info("#{group_name}: connected to #{target.node}")

          {:badrpc, reason} ->
            Mix.raise("harness #{harness_node} unreachable: #{inspect(reason)}")

          {:error, reason} ->
            Mix.raise("#{group_name}: connect failed: #{inspect(reason)}")
        end

      :error ->
        Mix.raise(
          "no deploy recorded for #{inspect(group_name)}, run `mix wiki_race.deploy #{group_name}` first"
        )
    end
  end
end
