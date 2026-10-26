defmodule WikiRacePlatformWeb.RaceLive do
  @moduledoc """
  The live race page: a circular start/target/timer display plus
  head-to-head panels, styled to be read from across a room. When a race
  finishes, the panels stay up and show the verified path, final state
  badge, and winner highlight instead of switching to a separate summary.

  The harness pushes every race update here over PubSub. The clock ticks
  on its own between updates so it keeps moving.
  """

  use WikiRacePlatformWeb, :live_view

  import WikiRacePlatformWeb.RaceComponents

  alias WikiRacePlatform.Race
  alias WikiRacePlatform.Race.Result
  alias WikiRacePlatform.Tournament.Server, as: Tournament
  alias WikiRacePlatformWeb.NodeResolution

  @tick_ms 200

  embed_templates "race_live/*"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Race.subscribe()
      :timer.send_interval(@tick_ms, :tick)
    end

    {:ok,
     socket
     |> assign(
       snapshot: Race.snapshot(),
       progress: Tournament.progress(),
       next_fixture: Tournament.next_fixture(),
       error: nil,
       starting: false
     )
     |> assign_clock()}
  end

  @impl true
  def handle_info({:race_update, %{status: :finished} = snapshot}, socket) do
    {:noreply,
     socket
     |> assign(
       snapshot: snapshot,
       progress: Tournament.progress(),
       next_fixture: Tournament.next_fixture()
     )
     |> assign_clock()}
  end

  def handle_info({:race_update, snapshot}, socket) do
    {:noreply, socket |> assign(snapshot: snapshot) |> assign_clock()}
  end

  def handle_info(:tick, socket), do: {:noreply, assign_clock(socket)}

  @impl true
  def handle_event("start_next", _params, %{assigns: %{starting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("start_next", _params, socket) do
    case socket.assigns.next_fixture do
      nil ->
        {:noreply, socket}

      fixture ->
        {:noreply,
         socket
         |> assign(error: nil, starting: true)
         |> start_async(:start_next, fn -> start_match(fixture) end)}
    end
  end

  # On the university VMs this first starts both crawlers on the player
  # VMs, which takes a few seconds (see `NodeResolution`).
  defp start_match(fixture) do
    with {:ok, node_mapping} <- NodeResolution.resolve(fixture) do
      Tournament.start_next!(node_mapping)
    end
  end

  @impl true
  def handle_async(:start_next, {:ok, {:ok, snapshot}}, socket) do
    {:noreply, socket |> assign(snapshot: snapshot, starting: false) |> assign_clock()}
  end

  def handle_async(:start_next, {:ok, {:error, message}}, socket) do
    {:noreply, assign(socket, starting: false, error: message)}
  end

  def handle_async(:start_next, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       starting: false,
       error: "starting the match failed: #{inspect(reason)}"
     )}
  end

  @impl true
  def render(assigns)

  attr :snapshot, :map, required: true
  attr :elapsed, :integer, required: true
  attr :progress, :map, required: true
  def race_header(assigns)

  attr :progress, :map, required: true
  def no_live_match(assigns)

  attr :next_fixture, :any, required: true
  attr :error, :any, required: true
  attr :starting, :boolean, required: true
  def next_match_control(assigns)

  defp fixture_summary({:bye, name}), do: "#{name}, solo time trial"
  defp fixture_summary({a, b}), do: "#{a} vs #{b}"

  defp idle_title(%{complete: true}), do: "TOURNAMENT COMPLETE"
  defp idle_title(_progress), do: "NO RACE RUNNING"

  defp idle_hint(%{complete: true}), do: "final results"
  defp idle_hint(_progress), do: "the next match"

  defp round_label(%{complete: true}), do: "TOURNAMENT COMPLETE"
  defp round_label(%{round: round, total_rounds: total}), do: "ROUND #{round} OF #{total}"

  defp format_ms_clock(ms) do
    total_seconds = div(ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}:#{String.pad_leading("#{seconds}", 2, "0")}"
  end

  defp timer_ring_style(elapsed, %{time_limit_ms: limit})
       when is_integer(limit) and limit > 0 do
    degrees = elapsed |> Kernel./(limit) |> min(1.0) |> Kernel.*(360)
    formatted = :erlang.float_to_binary(degrees, decimals: 1)

    "background: conic-gradient(#000 #{formatted}deg, var(--color-comic-paper-dim) #{formatted}deg);"
  end

  defp timer_ring_style(_elapsed, _config),
    do: "background: var(--color-comic-paper-dim);"

  defp winner?(%{result: %Result{winner: %{node: node}}}, player), do: player.node == node
  defp winner?(_snapshot, _player), do: false

  # The harness only sends updates on its poll tick, which can be slow.
  # The clock is recomputed locally so it never looks stuck.
  defp assign_clock(socket) do
    snapshot = socket.assigns.snapshot

    elapsed =
      case snapshot do
        %{status: :running, started_at_utc: %DateTime{} = started} ->
          DateTime.diff(DateTime.utc_now(), started, :millisecond)

        %{elapsed_ms: elapsed} ->
          elapsed
      end

    assign(socket, elapsed: max(elapsed, 0))
  end
end
