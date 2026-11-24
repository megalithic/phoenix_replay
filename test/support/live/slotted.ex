defmodule PhoenixReplay.Test.Live.Slotted do
  @moduledoc "View that passes slots to a LiveComponent."

  use Phoenix.LiveView

  alias PhoenixReplay.Test.Live.Panel

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, title: "Notes")}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={Panel} id="panel">
      <:header>{@title}</:header>
      <p class="body">Inner content</p>
    </.live_component>
    """
  end
end

defmodule PhoenixReplay.Test.Live.Panel do
  @moduledoc "Component that renders its slots and keeps its own count."

  use Phoenix.LiveComponent

  @impl true
  def mount(socket), do: {:ok, assign(socket, opened: 0)}

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, update(socket, :opened, &(&1 + 1))}

  @impl true
  def render(assigns) do
    ~H"""
    <section id="panel">
      <h2>{render_slot(@header)}</h2>
      {render_slot(@inner_block)}
      <span class="opened">{@opened}</span>
      <button phx-click="open" phx-target={@myself}>Open</button>
    </section>
    """
  end
end
