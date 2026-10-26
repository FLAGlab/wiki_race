defmodule WikiRacePlatform.Deploy.MatchTest do
  use ExUnit.Case, async: false

  alias WikiRacePlatform.Deploy.Match
  alias WikiRacePlatform.Deploy.Server
  alias WikiRacePlatform.FakeRelease
  alias WikiRacePlatform.FakeTransport

  # "player1" and "player2" are entries of the local priv/groups.exs. They
  # have no slug, so their releases live in /home/deploy/releases/player.
  @hosts ["vm1", "vm2"]

  setup do
    test_pid = self()
    FakeRelease.script(%{})

    FakeTransport.script(%{
      exec: fn {:fake_conn, host}, command ->
        send(test_pid, {:exec, host, command})
        {:ok, "", 0}
      end
    })

    :ok
  end

  defp start_server(opts \\ []) do
    id = System.unique_integer([:positive])
    name = :"match_deploy_server_#{id}"
    task_sup = :"match_task_sup_#{id}"

    start_supervised!(%{
      id: task_sup,
      start: {Task.Supervisor, :start_link, [[name: task_sup]]}
    })

    default_opts = [
      name: name,
      transport: FakeTransport,
      release_builder: FakeRelease,
      task_supervisor: task_sup,
      connect: fn _node -> true end,
      connected_nodes: fn -> [:player1@vm1, :player2@vm2] end,
      join_timeout_ms: 200,
      join_poll_ms: 50
    ]

    start_supervised!({Server, Keyword.merge(default_opts, opts)})
    name
  end

  defp prepare(fixture, server, opts \\ []) do
    Match.prepare(
      fixture,
      Keyword.merge(
        [server: server, hosts: @hosts, app_started?: fn _node, _app -> true end],
        opts
      )
    )
  end

  defp execs do
    receive do
      {:exec, host, command} -> [{host, command} | execs()]
    after
      100 -> []
    end
  end

  test "stops both player VMs, then starts each group on its own VM" do
    server = start_server()

    assert {:ok, mapping} = prepare({"player1", "player2"}, server)
    assert mapping == %{"player1" => :player1@vm1, "player2" => :player2@vm2}

    commands = execs()
    {clears, starts} = Enum.split(commands, 2)

    assert Enum.sort(Enum.map(clears, &elem(&1, 0))) == @hosts
    assert Enum.all?(clears, fn {_host, command} -> command =~ "pkill" end)

    assert [{"vm1", start1}] = for({"vm1", c} <- starts, c =~ "daemon", do: {"vm1", c})
    assert [{"vm2", start2}] = for({"vm2", c} <- starts, c =~ "daemon", do: {"vm2", c})
    assert start1 =~ "cd /home/deploy/releases/player"
    assert start1 =~ "RELEASE_NODE=player1@vm1"
    assert start2 =~ "RELEASE_NODE=player2@vm2"

    [_, cookie1] = Regex.run(~r/RELEASE_COOKIE=(\S+)/, start1)
    [_, cookie2] = Regex.run(~r/RELEASE_COOKIE=(\S+)/, start2)
    refute cookie1 == cookie2
  end

  test "a bye starts its group on the first VM and leaves the second one empty" do
    server = start_server()

    assert {:ok, %{"player1" => :player1@vm1}} = prepare({:bye, "player1"}, server)

    commands = execs()
    assert Enum.count(commands, fn {_host, c} -> c =~ "pkill" end) == 2
    assert [{"vm1", _}] = Enum.filter(commands, fn {_host, c} -> c =~ "daemon" end)
  end

  test "a crawler that never joins is reported with its group and VM" do
    server = start_server(connected_nodes: fn -> [:player1@vm1] end)

    assert {:error, message} = prepare({"player1", "player2"}, server)
    assert message =~ "player2 on vm2"
    assert message =~ "did_not_join"
  end

  test "a crawler whose app never starts is reported" do
    server = start_server()

    assert {:error, message} =
             prepare({"player1", "player2"}, server,
               app_started?: fn node, _app -> node == :player1@vm1 end,
               app_timeout_ms: 300
             )

    assert message =~ "player2 on vm2: player did not start"
  end

  test "a player VM that cannot be stopped fails the match before starting anything" do
    FakeTransport.script(%{
      connect: fn
        "vm2", _opts -> {:error, :ehostunreach}
        host, _opts -> {:ok, {:fake_conn, host}}
      end
    })

    server = start_server()

    assert {:error, message} = prepare({"player1", "player2"}, server)
    assert message =~ "could not stop the crawler on vm2"
  end

  test "more groups than player VMs is an error" do
    server = start_server()

    assert {:error, message} =
             Match.prepare({"player1", "player2"}, server: server, hosts: ["vm1"])

    assert message =~ "only 1 player VMs"
  end

  test "the node of a group is its slug at the host" do
    assert Match.node_for(%{name: "Los Cangrejos"}, "10.0.0.1") ==
             :"los_cangrejos@10.0.0.1"
  end
end
