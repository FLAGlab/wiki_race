defmodule WikiRacePlatform.Deploy.GroupsFileTest do
  use ExUnit.Case, async: true

  alias WikiRacePlatform.Deploy.GroupsFile

  @moduletag :tmp_dir

  defp write(dir, contents) do
    path = Path.join(dir, "groups.txt")
    File.write!(path, contents)
    path
  end

  test "reads every group, skipping comments and blank lines", %{tmp_dir: dir} do
    path =
      write(dir, """
      # name | repo | tag | dir

      Los Cangrejos | https://github.com/a/wiki_race.git | final
      Mutex  Maniacs!| https://github.com/b/crawler.git |v1 | .
      """)

    assert [cangrejos, mutex] = GroupsFile.read!(path)

    assert cangrejos == %{
             name: "Los Cangrejos",
             slug: "los_cangrejos",
             repo: "https://github.com/a/wiki_race.git",
             tag: "final",
             dir: "player",
             checkout: Path.join([dir, "groups", "los_cangrejos"])
           }

    assert mutex.name == "Mutex  Maniacs!"
    assert mutex.slug == "mutex_maniacs"
    assert mutex.tag == "v1"
    assert mutex.dir == "."
  end

  test "a line without a tag is an error that names the line", %{tmp_dir: dir} do
    path = write(dir, "# header\nLos Cangrejos | https://github.com/a/wiki_race.git\n")

    assert_raise RuntimeError,
                 ~r/groups\.txt:2: expected `name \| repo \| tag \| dir`/,
                 fn ->
                   GroupsFile.read!(path)
                 end
  end

  test "two names with the same slug are rejected", %{tmp_dir: dir} do
    path =
      write(dir, """
      Los Cangrejos | https://github.com/a/x.git | final
      los cangrejos | https://github.com/b/y.git | final
      """)

    assert_raise RuntimeError, ~r/repeated slug/, fn -> GroupsFile.read!(path) end
  end
end
