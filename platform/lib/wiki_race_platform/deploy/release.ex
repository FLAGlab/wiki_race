defmodule WikiRacePlatform.Deploy.Release do
  @moduledoc """
  Builds a group's `mix release` inside a container pinned to the exact
  base image the simulated (and eventually real) player VMs run on. This
  keeps the result binary-compatible regardless of what OS the platform
  process itself runs on.

  Shells out to `docker compose run`. It never assumes the platform process
  is itself containerized: this runs the platform on the host (or wherever
  the repo checkout lives), as in "Running without Docker Compose" in
  `DEPLOY.md`. Running the platform itself inside
  the `platform` compose service, and reaching `docker`/the group checkouts
  from in there, is future work (it needs the docker socket and the repo
  bind-mounted in). Not attempted here.

  With `config :wiki_race_platform, :deploy, builder: :native`, the release
  is built with the Erlang and Elixir of the platform host instead, without
  Docker. This is only binary-compatible when the platform host runs the
  same OS as the player VMs, as on the university VMs (see
  `deploy/final/`).
  """

  alias WikiRacePlatform.Deploy.Manifest

  @type on_output :: (String.t() -> any())

  @build_cmd "MIX_ENV=prod mix deps.get && MIX_ENV=prod mix release --overwrite"

  @doc """
  Builds `group`'s release and packages it into a single tarball.

  Streams each line of the build's output to `on_output` as it happens, so
  a caller (`Deploy.Server`) can forward it live rather than dump it all at
  once when the build finishes.
  """
  @spec build(Manifest.group(), on_output()) :: {:ok, String.t()} | {:error, term()}
  def build(group, on_output \\ fn _line -> :ok end) do
    case run_build(builder(), group, on_output) do
      {:ok, 0} -> package(group)
      {:ok, status} -> {:error, {:build_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp builder do
    :wiki_race_platform
    |> Application.get_env(:deploy, [])
    |> Keyword.get(:builder, :docker)
  end

  defp run_build(:docker, group, on_output) do
    args = [
      "compose",
      "run",
      "--rm",
      "-v",
      "#{group.path}:/src",
      "release_builder",
      "sh",
      "-c",
      "cd /src && " <> @build_cmd
    ]

    run_streaming("docker", args, repo_root(), on_output)
  end

  # The build runs in the group's checkout, as its own OS process, with its
  # errors in the streamed log. ERL_AFLAGS is the platform's own (see
  # deploy/final/lib.sh) and is no business of the build.
  defp run_build(:native, group, on_output) do
    run_streaming("sh", ["-c", "exec 2>&1; " <> @build_cmd], group.path, on_output, [
      {~c"ERL_AFLAGS", false}
    ])
  end

  defp package(group) do
    rel_dir = Path.join([group.path, "_build", "prod", "rel"])
    app = Atom.to_string(group.app)

    tarball =
      Path.join(System.tmp_dir!(), "#{app}-#{System.unique_integer([:positive])}.tar.gz")

    case System.cmd("tar", ["-czf", tarball, "-C", rel_dir, app], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, tarball}
      {output, status} -> {:error, {:package_failed, status, output}}
    end
  end

  defp repo_root, do: Path.expand("..", File.cwd!())

  defp run_streaming(command, args, cd, on_output, env \\ []) do
    executable = System.find_executable(command) || raise "#{command} not found on PATH"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 100_000},
        args: args,
        cd: cd,
        env: env
      ])

    collect_lines(port, on_output)
  end

  defp collect_lines(port, on_output) do
    receive do
      {^port, {:data, {_eol_or_noeol, line}}} ->
        on_output.(line)
        collect_lines(port, on_output)

      {^port, {:exit_status, status}} ->
        {:ok, status}
    after
      600_000 -> {:error, :timeout}
    end
  end
end
