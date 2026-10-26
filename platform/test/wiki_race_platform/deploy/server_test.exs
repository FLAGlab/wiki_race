defmodule WikiRacePlatform.Deploy.ServerTest do
  use ExUnit.Case, async: false

  alias WikiRacePlatform.Deploy.Server
  alias WikiRacePlatform.FakeRelease
  alias WikiRacePlatform.FakeTransport

  @group "Local fixture"
  @target %{host: "player_vm1", node: :playera@player_vm1}

  setup do
    FakeTransport.script(%{})
    FakeRelease.script(%{})
    :ok
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_server(opts) do
    name = unique_name("deploy_server")

    task_sup = unique_name("deploy_task_sup")

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
      connected_nodes: fn -> [] end,
      join_timeout_ms: 200,
      join_poll_ms: 50
    ]

    spec = %{id: name, start: {Server, :start_link, [Keyword.merge(default_opts, opts)]}}
    start_supervised!(spec)
    name
  end

  test "deploy! moves through building, uploading, then stopped (deployed, not started)" do
    server = start_server([])
    Server.subscribe(@group)

    assert :ok = Server.deploy!(@group, @target, server)

    assert_receive {:deploy_update, @group, :building, _line}, 1_000
    assert_receive {:deploy_update, @group, :uploading, nil}, 1_000
    assert_receive {:deploy_update, @group, :stopped, nil}, 1_000

    assert Server.status(@group, server) == %{deploy: :stopped, connected: false}
  end

  test "deploy! refuses a second deploy while one is already in flight" do
    FakeRelease.script(%{
      build: fn _group, _on_output ->
        Process.sleep(200)
        {:ok, "/tmp/fake.tar.gz"}
      end
    })

    server = start_server([])

    assert :ok = Server.deploy!(@group, @target, server)
    assert {:error, message} = Server.deploy!(@group, @target, server)
    assert message =~ "already busy"
  end

  test "a failed build is reported as an error status, not silently dropped" do
    FakeRelease.script(%{build: fn _group, _on_output -> {:error, :build_broke} end})

    server = start_server([])
    Server.subscribe(@group)

    assert :ok = Server.deploy!(@group, @target, server)

    assert_receive {:deploy_update, @group, {:error, :build_broke}, nil}, 1_000
  end

  test "start! waits for the node to join and reports running when it does" do
    server = start_server(connected_nodes: fn -> [@target.node] end)
    Server.subscribe(@group)

    # deploy! first, so start! has a target to work from.
    Server.deploy!(@group, @target, server)
    drain_deploy(@group)

    assert :ok = Server.start!(@group, server)

    assert_receive {:deploy_update, @group, :running, nil}, 1_000
    assert Server.status(@group, server) == %{deploy: :running, connected: true}
  end

  test "start! reports it never joined, instead of hanging or silently succeeding" do
    server = start_server(connected_nodes: fn -> [] end)
    Server.subscribe(@group)

    Server.deploy!(@group, @target, server)
    drain_deploy(@group)

    assert :ok = Server.start!(@group, server)

    assert_receive {:deploy_update, @group, {:error, :did_not_join}, nil}, 1_000
  end

  test "each deploy gets its own random cookie, never this app's own" do
    test_pid = self()

    FakeTransport.script(%{
      exec: fn _conn, command ->
        send(test_pid, {:exec, command})
        {:ok, "", 0}
      end
    })

    server = start_server(connected_nodes: fn -> [@target.node] end)
    Server.subscribe(@group)

    Server.deploy!(@group, @target, server)
    drain_deploy(@group)
    Server.start!(@group, server)
    assert_receive {:deploy_update, @group, :running, nil}, 1_000
    first_cookie = await_start_cookie()

    refute first_cookie == to_string(Node.get_cookie())
    refute first_cookie == "wikirace"

    # A second deploy of the same group gets a *different* random cookie,
    # not a fixed secret reused across every deploy.
    Server.deploy!(@group, @target, server)
    drain_deploy(@group)
    Server.start!(@group, server)
    assert_receive {:deploy_update, @group, :running, nil}, 1_000
    second_cookie = await_start_cookie()

    refute second_cookie == first_cookie
  end

  # The deploy phase execs mkdir/tar commands too, on the same mocked
  # transport. Drain until the one that actually starts the daemon.
  defp await_start_cookie do
    receive do
      {:exec, command} ->
        case Regex.run(~r/RELEASE_COOKIE=(\S+).*daemon/, command) do
          [_, cookie] -> cookie
          nil -> await_start_cookie()
        end
    after
      1_000 -> flunk("never saw a daemon start command")
    end
  end

  test "start! provisions TLS certs and passes RELEASE_VM_ARGS when configured" do
    test_pid = self()

    Application.put_env(:wiki_race_platform, :deploy,
      tls: true,
      tls_certs_dir: "../deploy/certs"
    )

    on_exit(fn -> Application.delete_env(:wiki_race_platform, :deploy) end)

    FakeTransport.script(%{
      exec: fn _conn, command ->
        send(test_pid, {:exec, command})
        {:ok, "", 0}
      end,
      upload: fn _conn, local_path, remote_path ->
        send(test_pid, {:upload, local_path, remote_path})
        :ok
      end
    })

    server = start_server(connected_nodes: fn -> [@target.node] end)
    Server.subscribe(@group)

    Server.deploy!(@group, @target, server)
    drain_deploy(@group)
    Server.start!(@group, server)
    assert_receive {:deploy_update, @group, :running, nil}, 1_000

    # 6 uploads total: the release tarball (deploy!) plus the 5 TLS
    # provisioning files (start!).
    uploaded = for _ <- 1..6, do: receive(do: ({:upload, _local, remote} -> remote))

    for suffix <- [
          "tls/player.conf",
          "tls/vm.args.extra",
          "tls/player.pem",
          "tls/player.key",
          "tls/ca.pem"
        ] do
      assert Enum.any?(uploaded, &String.ends_with?(&1, suffix)),
             "expected an upload ending in #{suffix}, got #{inspect(uploaded)}"
    end

    start_cmd = await_start_command()
    assert start_cmd =~ ~r/RELEASE_VM_ARGS=\S*tls\/vm\.args\.extra/
  end

  defp await_start_command do
    receive do
      {:exec, command} ->
        if command =~ "daemon", do: command, else: await_start_command()
    after
      1_000 -> flunk("never saw a daemon start command")
    end
  end

  test "start! without a prior deploy is a clean error" do
    server = start_server([])
    assert {:error, message} = Server.start!(@group, server)
    assert message =~ "no deploy target"
  end

  test "stop! execs the remote stop command and reports stopped" do
    test_pid = self()

    server = start_server([])
    Server.subscribe(@group)

    Server.deploy!(@group, @target, server)
    drain_deploy(@group)

    FakeTransport.script(%{
      exec: fn _conn, command ->
        send(test_pid, {:exec, command})
        {:ok, "", 0}
      end
    })

    assert :ok = Server.stop!(@group, server)

    assert_receive {:exec, command}, 1_000
    assert command =~ "bin/player stop"
    assert_receive {:deploy_update, @group, :stopped, nil}, 1_000
  end

  test "deploy! to several targets builds once and unpacks on every host" do
    test_pid = self()

    FakeRelease.script(%{
      build: fn _group, _on_output ->
        send(test_pid, :built)
        {:ok, "/tmp/fake.tar.gz"}
      end
    })

    FakeTransport.script(%{
      exec: fn {:fake_conn, host}, command ->
        send(test_pid, {:exec, host, command})
        {:ok, "", 0}
      end
    })

    server = start_server([])
    Server.subscribe(@group)

    targets = [
      %{host: "vm1", node: :local_fixture@vm1},
      %{host: "vm2", node: :local_fixture@vm2}
    ]

    assert :ok = Server.deploy!(@group, targets, server)
    drain_deploy(@group)

    assert_received :built
    refute_received :built

    for host <- ["vm1", "vm2"] do
      assert_received {:exec, ^host, "tar -xzf /home/deploy/releases/player.tar.gz" <> _}
    end
  end

  test "a group with a slug gets its own release folder" do
    test_pid = self()
    group = %{name: "Los Cangrejos", slug: "los_cangrejos", app: :player}

    assert Server.release_dir(group) == "los_cangrejos"
    assert Server.release_dir(%{name: "x", app: :player}) == "player"

    FakeTransport.script(%{
      exec: fn _conn, command ->
        send(test_pid, {:exec, command})
        {:ok, "", 0}
      end
    })

    # Deploy the local fixture, then check where it unpacks: the manifest
    # entries of the local setup have no slug, so they keep the app folder.
    server = start_server([])
    Server.subscribe(@group)
    Server.deploy!(@group, @target, server)
    drain_deploy(@group)

    assert_received {:exec, "mkdir -p /home/deploy/releases/player"}

    assert_received {:exec,
                     "tar -xzf /home/deploy/releases/player.tar.gz -C /home/deploy/releases/player --strip-components=1"}
  end

  test "clear_host stops every release on that host and marks its group stopped" do
    test_pid = self()

    FakeTransport.script(%{
      exec: fn {:fake_conn, host}, command ->
        send(test_pid, {:exec, host, command})
        {:ok, "", 0}
      end
    })

    server = start_server(connected_nodes: fn -> [@target.node] end)
    Server.subscribe(@group)
    Server.deploy!(@group, @target, server)
    drain_deploy(@group)
    Server.start!(@group, server)
    assert_receive {:deploy_update, @group, :running, nil}, 1_000

    assert :ok = Server.clear_host(@target.host, server)
    assert_received {:exec, "player_vm1", "pkill -U" <> _}
    assert Server.status(@group, server).deploy == :stopped
  end

  test "clear_host reports an unreachable host" do
    FakeTransport.script(%{connect: fn _host, _opts -> {:error, :econnrefused} end})
    server = start_server([])

    assert {:error, :econnrefused} = Server.clear_host("vm9", server)
  end

  # Consumes the deploy sequence's broadcasts up through :stopped, so a test
  # driving start!/stop! afterwards starts from a clean mailbox.
  defp drain_deploy(group) do
    receive do
      {:deploy_update, ^group, :stopped, _} -> :ok
      {:deploy_update, ^group, _other, _} -> drain_deploy(group)
    after
      2_000 -> flunk("deploy never reached :stopped")
    end
  end
end
