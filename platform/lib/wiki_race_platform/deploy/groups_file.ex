defmodule WikiRacePlatform.Deploy.GroupsFile do
  @moduledoc """
  The groups of a tournament on the university VMs, read from
  `deploy/final/groups.txt` (or the file in `WIKI_RACE_GROUPS_FILE`).

  One group per line, fields separated by `|`:

      Los Cangrejos | https://github.com/someone/wiki_race.git | final | player

  The fields are the name the dashboard shows, the public repository, the
  tag to race, and the folder of the player inside the repository. The
  folder is optional and defaults to `player`, the folder of the template.
  Use `.` when `mix.exs` is at the root of the repository. Blank lines and
  lines starting with `#` are ignored.

  `mix wiki_race.fetch` clones each group into `checkout`, under
  `deploy/final/groups/<slug>`. `priv/groups.exs` turns every entry into a
  manifest group, and `config/runtime.exs` makes the names the tournament
  roster. The slug also names the release folder on the player VMs and the
  node of the group (see `WikiRacePlatform.Deploy.Match`).
  """

  @type entry :: %{
          name: String.t(),
          slug: String.t(),
          repo: String.t(),
          tag: String.t(),
          dir: String.t(),
          checkout: String.t()
        }

  @doc "The groups file: `WIKI_RACE_GROUPS_FILE`, or `deploy/final/groups.txt` of this repo."
  @spec path() :: String.t()
  def path do
    System.get_env("WIKI_RACE_GROUPS_FILE") ||
      Path.expand("../deploy/final/groups.txt", File.cwd!())
  end

  @doc "Every group in the file, in file order. Raises on a malformed line or a repeated name."
  @spec read!(String.t()) :: [entry()]
  def read!(file \\ path()) do
    checkouts = Path.join(Path.dirname(file), "groups")

    entries =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} -> {String.trim(line), number} end)
      |> Enum.reject(fn {line, _number} ->
        line == "" or String.starts_with?(line, "#")
      end)
      |> Enum.map(fn {line, number} -> parse!(line, number, file, checkouts) end)

    check_unique!(entries, :name, file)
    check_unique!(entries, :slug, file)
    entries
  end

  @doc "The name in lowercase, with every run of other characters turned into `_`."
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp parse!(line, number, file, checkouts) do
    case line |> String.split("|") |> Enum.map(&String.trim/1) do
      [name, repo, tag | rest] when name != "" and repo != "" and tag != "" ->
        dir =
          case rest do
            [] ->
              "player"

            [""] ->
              "player"

            [dir] ->
              dir

            _ ->
              raise "#{file}:#{number}: expected at most 4 fields, got #{inspect(line)}"
          end

        slug = slug(name)

        if slug == "",
          do: raise("#{file}:#{number}: the name #{inspect(name)} has no letters")

        %{
          name: name,
          slug: slug,
          repo: repo,
          tag: tag,
          dir: dir,
          checkout: Path.join(checkouts, slug)
        }

      _ ->
        raise "#{file}:#{number}: expected `name | repo | tag | dir`, got #{inspect(line)}"
    end
  end

  defp check_unique!(entries, key, file) do
    entries
    |> Enum.frequencies_by(& &1[key])
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> case do
      [] ->
        :ok

      repeated ->
        raise "#{file}: repeated #{key}: #{inspect(Enum.map(repeated, &elem(&1, 0)))}"
    end
  end
end
