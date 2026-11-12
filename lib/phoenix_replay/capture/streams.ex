defmodule PhoenixReplay.Capture.Streams do
  @moduledoc """
  Takes what a render changes in a LiveView's or LiveComponent's streams,
  when `:streams` is configured.

  A stream keeps no items on the server: `stream/4`, `stream_insert/4` and
  `stream_delete/3` queue operations, which the next render sends to the
  browser and then drops. They are taken while still queued, before the
  render clears them, as `t:PhoenixReplay.Recording.Streams.ops/0`, which
  `PhoenixReplay.Recording.Streams` applies again on replay.

  Items go through `sanitize_assigns/1` of the session's
  `PhoenixReplay.Sanitizer` as a list under the stream's name, as an
  assign of that name would. A sanitizer that leaves that name out, or
  does not return a list of as many items, leaves the stream out.
  """

  alias Phoenix.LiveView.LiveStream
  alias PhoenixReplay.Recording.Streams

  @doc """
  The operations queued in `streams`, a LiveView's `@streams`, by stream
  name, with items sanitized: those of each stream changed since the last
  render, which LiveView lists under `:__changed__`, so a stream defined
  empty is kept too.
  """
  @spec pending(map(), module()) :: %{Streams.name() => Streams.ops()}
  def pending(%{__changed__: changed} = streams, sanitizer) do
    for name <- changed,
        %LiveStream{} = stream <- [streams[name]],
        {:ok, ops} <- [ops(name, stream, sanitizer)],
        into: %{},
        do: {name, ops}
  end

  def pending(_streams, _sanitizer), do: %{}

  # Inserts are queued newest first. A row inserted twice renders once, in
  # the order and with the item of its last insert, but the browser places
  # it as its first insert said: it reads each insert's placement in queue
  # order, so the oldest is read last.
  defp ops(name, stream, sanitizer) do
    inserts = stream.inserts |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
    items = Enum.map(inserts, &elem(&1, 2))

    placement =
      Map.new(stream.inserts, fn {dom_id, at, _item, limit, update_only} ->
        {dom_id, {at, limit, update_only}}
      end)

    with %{^name => sanitized} when is_list(sanitized) <-
           sanitizer.sanitize_assigns(%{name => items}),
         true <- length(sanitized) == length(items) do
      {:ok,
       %{
         reset?: stream.reset?,
         deletes: Enum.reverse(stream.deletes),
         inserts: Enum.zip_with(inserts, sanitized, &insert(&1, &2, placement))
       }}
    else
      _left_out -> :error
    end
  end

  defp insert({dom_id, _at, _item, _limit, _update_only}, item, placement) do
    {at, limit, update_only} = Map.fetch!(placement, dom_id)
    %{dom_id: dom_id, at: at, limit: limit, update_only: update_only == true, item: item}
  end
end
