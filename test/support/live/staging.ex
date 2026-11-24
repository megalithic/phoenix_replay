defmodule PhoenixReplay.Test.Live.Staging do
  @moduledoc "View that stages rows in a stream and takes a CSV upload, with a component that has its own."

  use Phoenix.LiveView

  alias PhoenixReplay.Test.Live.Notes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:rows, dom_id: &"row-#{&1.id}")
     |> stream(:rows, [row("alpha")])
     |> allow_upload(:csv, accept: ~w(.csv), max_entries: 2)}
  end

  @impl true
  def handle_event("append", %{"name" => name}, socket),
    do: {:noreply, stream_insert(socket, :rows, row(name), limit: -3)}

  def handle_event("prepend", %{"name" => name}, socket),
    do: {:noreply, stream_insert(socket, :rows, row(name), at: 0)}

  def handle_event("rename", %{"id" => id, "name" => name}, socket),
    do: {:noreply, stream_insert(socket, :rows, %{id: id, name: name})}

  def handle_event("remove", %{"id" => id}, socket),
    do: {:noreply, stream_delete(socket, :rows, %{id: id})}

  def handle_event("reset", %{"name" => name}, socket),
    do: {:noreply, stream(socket, :rows, [row(name)], reset: true)}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  defp row(name), do: %{id: name, name: name}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload" phx-change="validate">
      <.live_file_input upload={@uploads.csv} />
    </form>
    <p :for={entry <- @uploads.csv.entries} class="entry">{entry.client_name}</p>
    <ul id="rows" phx-update="stream">
      <li :for={{dom_id, row} <- @streams.rows} id={dom_id}>{row.name}</li>
    </ul>
    <.live_component module={Notes} id="notes" />
    """
  end
end
