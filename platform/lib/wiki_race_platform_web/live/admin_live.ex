defmodule WikiRacePlatformWeb.AdminLive do
  @moduledoc """
  Race control. Pick the article pair for the current match, start the
  next match, advance once one finishes, or abort if something goes wrong.

  There is no login. The platform runs on a private network and only the
  professor can reach it.

  Deployment is terminal-only (`mix wiki_race.deploy`/`.start`/`.stop`). A
  node must already be connected under the name from its group's
  `priv/groups.exs` entry, so starting a match here never needs a manual
  node picker. On the university VMs, starting a match also starts the two
  crawlers on the player VMs first (see `WikiRacePlatformWeb.NodeResolution`),
  so it runs in `start_async/3`.
  """

  use WikiRacePlatformWeb, :live_view

  alias WikiRacePlatform.Articles
  alias WikiRacePlatform.Race
  alias WikiRacePlatform.Tournament.Server, as: Tournament
  alias WikiRacePlatform.Tournament.Store
  alias WikiRacePlatformWeb.NodeResolution

  embed_templates "admin_live/*"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Race.subscribe()
    end

    {:ok,
     socket
     |> assign(snapshot: Race.snapshot(), error: nil, starting: false)
     |> assign(tournament_assigns())}
  end

  defp tournament_assigns do
    %{
      pairs: Articles.pairs(),
      pair: Tournament.current_pair(),
      pair_overridden: Tournament.pair_overridden?(),
      progress: Tournament.progress(),
      history: Tournament.history(),
      next_fixture: Tournament.next_fixture()
    }
  end

  @impl true
  def handle_info({:race_update, %{status: :finished} = snapshot}, socket) do
    {:noreply,
     socket
     |> assign(snapshot: snapshot)
     |> assign(tournament_assigns())}
  end

  def handle_info({:race_update, snapshot}, socket) do
    {:noreply, assign(socket, snapshot: snapshot)}
  end

  @impl true
  def handle_event("set_pair", %{"pair" => index}, socket) do
    pair = Enum.at(socket.assigns.pairs, String.to_integer(index))
    Tournament.set_pair(pair)

    {:noreply,
     assign(socket,
       pair: Tournament.current_pair(),
       pair_overridden: Tournament.pair_overridden?()
     )}
  end

  def handle_event("start_next", _params, %{assigns: %{starting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("start_next", _params, socket) do
    case Tournament.next_fixture() do
      nil ->
        {:noreply, assign(socket, error: "no fixture is queued")}

      fixture ->
        {:noreply,
         socket
         |> assign(error: nil, starting: true)
         |> start_async(:start_next, fn -> start_match(fixture) end)}
    end
  end

  def handle_event("abort", _params, socket) do
    case Race.abort() do
      {:ok, snapshot} -> {:noreply, assign(socket, snapshot: snapshot, error: nil)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event("restart_tournament", _params, socket) do
    Store.clear()
    Tournament.refresh()

    {:noreply, socket |> assign(error: nil) |> assign(tournament_assigns())}
  end

  @impl true
  def handle_async(:start_next, {:ok, {:ok, _snapshot}}, socket) do
    {:noreply, socket |> assign(starting: false) |> push_navigate(to: ~p"/")}
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

  defp start_match(fixture) do
    with {:ok, node_mapping} <- NodeResolution.resolve(fixture) do
      Tournament.start_next!(node_mapping)
    end
  end

  @impl true
  def render(assigns)

  attr :snapshot, :map, required: true
  def live_match(assigns)

  attr :pairs, :list, required: true
  attr :pair, :any, required: true
  attr :pair_overridden, :boolean, required: true
  attr :progress, :map, required: true
  attr :next_fixture, :any, required: true
  attr :history, :list, required: true
  attr :starting, :boolean, required: true
  def next_match(assigns)

  def danger_zone(assigns)

  defp round_pair_label(%{round: round}, true),
    do: "Round #{round} pair: custom, overrides the progression"

  defp round_pair_label(%{round: round}, false),
    do: "Round #{round} pair: from the configured progression"

  defp note_suffix(%{note: ""}), do: ""
  defp note_suffix(%{note: note}), do: ", #{note}"

  defp start_label(true, _history), do: "Starting the crawlers…"
  defp start_label(false, []), do: "▶ Start race"
  defp start_label(false, _history), do: "⏭ Advance to next match"

  defp fixture_summary({:bye, name}), do: "#{name}, solo time trial"
  defp fixture_summary({a, b}), do: "#{a} vs #{b}"
end
