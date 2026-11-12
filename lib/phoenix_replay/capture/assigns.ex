defmodule PhoenixReplay.Capture.Assigns do
  @moduledoc """
  Takes the assigns a recording keeps, before the sanitizer sees them.

  LiveView's own bookkeeping cannot be replayed, whatever the sanitizer
  does: change tracking, uploads and streams, and in a LiveComponent its
  `@myself` and the flash, which the parent view records. Streams and
  uploads are recorded apart, when configured, by
  `streams_and_uploads/3`.
  """

  alias PhoenixReplay.Capture.{Streams, Uploads}

  @view [:__changed__, :uploads, :streams]
  @component [:myself, :flash | @view]

  @doc "The assigns of a LiveView to record, sanitized."
  @spec view(map(), module()) :: map()
  def view(assigns, sanitizer), do: assigns |> Map.drop(@view) |> sanitizer.sanitize_assigns()

  @doc "The assigns of a LiveComponent to record, sanitized."
  @spec component(map(), module()) :: map()
  def component(assigns, sanitizer),
    do: assigns |> Map.drop(@component) |> sanitizer.sanitize_assigns()

  @doc """
  The streams and uploads in `assigns` that `kept` names, to record with
  the assigns: `:streams` with the operations queued in each stream, see
  `PhoenixReplay.Capture.Streams`, and `:uploads` with the state of each
  upload, see `PhoenixReplay.Capture.Uploads`. Each is left out when there
  is nothing to record.
  """
  @spec streams_and_uploads(map(), [:streams | :uploads], module()) :: map()
  def streams_and_uploads(assigns, kept, sanitizer) do
    for key <- kept,
        %{} = value <- [assigns[key]],
        taken = take(key, value, sanitizer),
        taken != %{},
        into: %{},
        do: {key, taken}
  end

  defp take(:streams, streams, sanitizer), do: Streams.pending(streams, sanitizer)
  defp take(:uploads, uploads, sanitizer), do: Uploads.state(uploads, sanitizer)
end
