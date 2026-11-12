defmodule PhoenixReplay.Test.Live.Notes do
  @moduledoc "Component that keeps notes in a stream, newest first, and takes photos."

  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> stream_configure(:notes, dom_id: &"note-#{&1.id}")
     |> stream(:notes, [])
     |> allow_upload(:photo, accept: :any, max_entries: 3)}
  end

  @impl true
  def handle_event("add", %{"text" => text}, socket),
    do: {:noreply, stream_insert(socket, :notes, %{id: text, text: text}, at: 0, limit: 2)}

  def handle_event("remove", %{"id" => id}, socket),
    do: {:noreply, stream_delete(socket, :notes, %{id: id})}

  def handle_event("clear", _params, socket),
    do: {:noreply, stream(socket, :notes, [], reset: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <ol id="note-list" phx-update="stream">
        <li :for={{dom_id, note} <- @streams.notes} id={dom_id}>{note.text}</li>
      </ol>
      <.live_file_input upload={@uploads.photo} />
      <button id="add-note" phx-click="add" phx-target={@myself}>Add</button>
      <button id="remove-note" phx-click="remove" phx-target={@myself}>Remove</button>
      <button id="clear-notes" phx-click="clear" phx-target={@myself}>Clear</button>
    </div>
    """
  end
end
