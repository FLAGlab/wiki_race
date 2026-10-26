defmodule Mix.Tasks.WikiRace.Stop do
  @moduledoc """
  Stops a group's running release.

      mix wiki_race.stop GROUP
      mix wiki_race.stop --all

  Needs the target/cookie an earlier `mix wiki_race.deploy GROUP` recorded
  (reattached here, same as `mix wiki_race.start`).

  `--all` stops every release on every player VM of `player_hosts` (the
  university VMs, see `WikiRacePlatform.Deploy.Match`), whichever group it
  belongs to. It needs no recorded cookie.
  """

  use Mix.Task

  alias WikiRacePlatform.Deploy.CliState
  alias WikiRacePlatform.Deploy.Match
  alias WikiRacePlatform.Deploy.Server, as: Deploy

  @shortdoc "Stops a group's running release"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--all"] -> stop_all()
      [name] -> stop(name)
      _ -> Mix.raise("usage: mix wiki_race.stop GROUP | mix wiki_race.stop --all")
    end
  end

  defp stop_all do
    if not Match.enabled?(),
      do: Mix.raise("--all needs player_hosts in the :deploy config")

    for host <- Match.player_hosts() do
      case Deploy.clear_host(host) do
        :ok -> Mix.shell().info("#{host}: nothing running")
        {:error, reason} -> Mix.raise("#{host}: #{inspect(reason)}")
      end
    end
  end

  defp stop(group_name) do
    case CliState.fetch(group_name) do
      {:ok, %{target: target, cookie: cookie}} ->
        Deploy.subscribe(group_name)
        Deploy.reattach!(group_name, target, cookie)

        case Deploy.stop!(group_name) do
          :ok -> await_terminal(group_name)
          {:error, message} -> Mix.raise("stop failed: #{message}")
        end

      :error ->
        Mix.raise(
          "no deploy recorded for #{inspect(group_name)}, run `mix wiki_race.deploy #{group_name}` first"
        )
    end
  end

  defp await_terminal(group_name) do
    receive do
      {:deploy_update, ^group_name, status, line} ->
        if line, do: Mix.shell().info(line)
        handle_status(group_name, status)
    after
      30_000 -> Mix.raise("timed out waiting for #{group_name} to stop")
    end
  end

  defp handle_status(group_name, :stopped) do
    Mix.shell().info("#{group_name}: stopped")
  end

  defp handle_status(group_name, {:error, reason}) do
    Mix.raise("#{group_name}: stop failed: #{inspect(reason)}")
  end

  defp handle_status(group_name, _in_progress_status), do: await_terminal(group_name)
end
