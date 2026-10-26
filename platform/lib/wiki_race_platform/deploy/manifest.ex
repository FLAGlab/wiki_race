defmodule WikiRacePlatform.Deploy.Manifest do
  @moduledoc """
  The per-group deployment manifest.

  Lives in `priv/groups.exs` so the professor can edit it after cloning a
  group's tagged submission by hand, without touching code or restarting
  the platform. Same reasoning as `WikiRacePlatform.Articles` and
  `priv/article_pairs.exs`.

  `host`/`node` (optional) are the group's player VM and the Erlang node
  name their release runs under once deployed. They are the default target
  for the terminal-only `mix wiki_race.deploy`/`.start`/`.stop` tasks, and
  how `ScheduleLive` resolves which connected node belongs to which roster
  name when starting a race, without a manual per-race node picker.

  `slug` (optional) names the folder of the group's release on a player VM
  (see `Deploy.Server.release_dir/1`). Every group of
  `deploy/final/groups.txt` has one.
  """

  @manifest_file "groups.exs"

  @type group :: %{
          optional(:slug) => String.t(),
          name: String.t(),
          app: atom(),
          repo: String.t(),
          tag: String.t(),
          sha: String.t(),
          path: String.t(),
          module: module() | nil,
          host: String.t() | nil,
          node: node() | nil
        }

  @doc "Every group in the manifest, in file order."
  @spec groups() :: [group()]
  def groups do
    {groups, _bindings} = Code.eval_file(manifest_path())
    groups
  end

  @doc "The group with this name, or raises. A missing group is a config error, not a runtime one to recover from."
  @spec group!(String.t()) :: group()
  def group!(name) do
    Enum.find(groups(), &(&1.name == name)) ||
      raise "no group named #{inspect(name)} in the deploy manifest"
  end

  @doc """
  Checks every group's `path` actually exists and its `app` matches what
  that checkout's `mix.exs` declares.

  Run this after editing the manifest or cloning a new group's tag. A wrong
  `path` or `app` fails the release build or start step in a way that looks
  like the group's own code is broken, which is a bad way to find out.
  """
  @spec check_groups() :: :ok | {:error, [String.t()]}
  def check_groups do
    problems = groups() |> Enum.flat_map(&check_group/1)
    if problems == [], do: :ok, else: {:error, problems}
  end

  defp check_group(group) do
    cond do
      not File.dir?(group.path) ->
        ["#{group.name}: path #{group.path} does not exist"]

      not File.exists?(Path.join(group.path, "mix.exs")) ->
        ["#{group.name}: #{group.path} has no mix.exs"]

      declared_app(group.path) != group.app ->
        [
          "#{group.name}: manifest says app #{inspect(group.app)}, " <>
            "mix.exs declares #{inspect(declared_app(group.path))}"
        ]

      true ->
        []
    end
  end

  # Uses a regex read, not `Code.eval_file/1`. A group's `mix.exs` defines a
  # `Mix.Project`, and evaluating it for real would register that project
  # in this VM's Mix session, alongside whatever the platform itself is
  # running under. This only needs the declared app name, not a working
  # project.
  defp declared_app(path) do
    source = File.read!(Path.join(path, "mix.exs"))

    case Regex.run(~r/app:\s*:(\w+)/, source) do
      [_, app] -> String.to_atom(app)
      nil -> nil
    end
  end

  defp manifest_path do
    Application.app_dir(:wiki_race_platform, ["priv", @manifest_file])
  end
end
