defmodule WikiRacePlatformWeb.AdminLiveTest do
  use WikiRacePlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WikiRacePlatform.Articles
  alias WikiRacePlatform.Race.Dispatcher
  alias WikiRacePlatform.Tournament.Server, as: Tournament

  setup do
    start_supervised!(Dispatcher)
    :ok
  end

  test "shows race control, the pair selector, and the next fixture", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin")

    assert html =~ "Race control"
    assert html =~ "Teacher-only"

    [first_pair | _] = Articles.pairs()
    assert html =~ first_pair.start
    assert html =~ first_pair.target
  end

  test "picking a pair from the dropdown becomes the tournament's current pair", %{
    conn: conn
  } do
    {:ok, live, _html} = live(conn, ~p"/admin")

    pairs = Articles.pairs()
    target_index = length(pairs) - 1
    target_pair = Enum.at(pairs, target_index)

    render_change(live, "set_pair", %{"pair" => to_string(target_index)})

    assert Tournament.current_pair() == target_pair
  end

  test "starting the next match without a configured node reports a clean error", %{
    conn: conn
  } do
    {:ok, live, _html} = live(conn, ~p"/admin")

    # The roster's group names ("Group A", ...) don't match priv/groups.exs's
    # single "Local fixture" entry in this dev/test setup, so resolving a
    # node for any real fixture is expected to fail cleanly rather than
    # start a race against a made-up node.
    case Tournament.next_fixture() do
      nil ->
        :ok

      _fixture ->
        render_click(live, "start_next", %{})
        assert render_async(live) =~ "no node configured for"
    end
  end
end
