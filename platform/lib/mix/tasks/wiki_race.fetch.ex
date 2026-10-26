defmodule Mix.Tasks.WikiRace.Fetch do
  @moduledoc """
  Clones every group of the groups file at its tag.

      mix wiki_race.fetch

  Reads `deploy/final/groups.txt` (see `WikiRacePlatform.Deploy.GroupsFile`)
  and clones each repository with `git clone --depth 1 --branch TAG` into
  `deploy/final/groups/<slug>`, replacing an earlier clone. Prints the
  commit of each group, to compare with the commit the group submitted. A
  group that fails does not stop the others. The failures are listed at
  the end.

  Git never asks for a password here: a repository that is private or
  misspelled fails right away.
  """

  use Mix.Task

  alias WikiRacePlatform.Deploy.GroupsFile

  @shortdoc "Clones every group of deploy/final/groups.txt at its tag"

  @impl Mix.Task
  def run(_args) do
    failures =
      Enum.flat_map(GroupsFile.read!(), fn group ->
        case fetch(group) do
          {:ok, commit} ->
            Mix.shell().info("#{group.name}: #{group.tag} at commit #{commit}")
            []

          {:error, message} ->
            Mix.shell().error("#{group.name}: #{message}")
            [group.name]
        end
      end)

    if failures != [] do
      Mix.raise("could not fetch: #{Enum.join(failures, ", ")}")
    end
  end

  defp fetch(group) do
    File.rm_rf!(group.checkout)
    File.mkdir_p!(Path.dirname(group.checkout))

    args = [
      "clone",
      "--quiet",
      "--depth",
      "1",
      "--branch",
      group.tag,
      group.repo,
      group.checkout
    ]

    with {_output, 0} <- git(args),
         {commit, 0} <- git(["-C", group.checkout, "rev-parse", "HEAD"]),
         :ok <- check_mix_project(group) do
      {:ok, String.trim(commit)}
    else
      {:error, message} -> {:error, message}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp check_mix_project(group) do
    if File.exists?(Path.join([group.checkout, group.dir, "mix.exs"])) do
      :ok
    else
      {:error, "no mix.exs in the folder #{inspect(group.dir)} of the repository"}
    end
  end

  defp git(args) do
    System.cmd("git", args, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}])
  end
end
