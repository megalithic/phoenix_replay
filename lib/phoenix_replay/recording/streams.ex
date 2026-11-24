defmodule PhoenixReplay.Recording.Streams do
  @moduledoc """
  The rows of recorded streams, rebuilt from the operations
  `PhoenixReplay.Capture.Streams` recorded, as LiveView's client applies
  them to the page:

    * a reset removes every row, then deletes remove rows by DOM id
    * an insert of a row already shown updates it in place
    * an insert with `update_only` changes only a row already shown, or
      one the same render removed, by reset, delete or limit, which the
      browser keeps to put back
    * a new row goes at `at`: `-1` appends it, `0` prepends it, and `n`
      puts it at index `n`, or last when there are fewer rows
    * then a `limit` keeps the first `limit` rows, or the last `-limit`
      when negative

  `PhoenixReplay.Recording.Timeline` keeps the rows under the `:streams`
  key of a view's or component's assigns, which no assign can have,
  `%{name => [{dom_id, item}]}`, in the order the page shows them.
  Operations of any other shape, as a corrupt recording may hold, change
  nothing.
  """

  @typedoc "A row a render inserted or updated."
  @type insert :: %{
          dom_id: String.t(),
          at: integer(),
          limit: integer() | nil,
          update_only: boolean(),
          item: term()
        }

  @typedoc """
  What a render changed in one stream: whether it was reset, the DOM ids
  of the rows it deleted, and the rows it inserted, in the order they
  render.
  """
  @type ops :: %{reset?: boolean(), deletes: [String.t()], inserts: [insert()]}

  @typedoc "A stream's rows: each one's DOM id and item, in page order."
  @type rows :: [{String.t(), term()}]

  @typedoc "A stream's name, as given to `Phoenix.LiveView.stream/4`."
  @type name :: atom() | String.t()

  @doc "Applies each stream's recorded operations to its rows."
  @spec apply(%{name() => rows()}, %{name() => ops()}) :: %{name() => rows()}
  def apply(streams, ops) when is_non_struct_map(ops) do
    Enum.reduce(ops, streams, fn {name, ops}, acc ->
      Map.put(acc, name, apply_ops(Map.get(acc, name, []), ops))
    end)
  end

  def apply(streams, _ops), do: streams

  defp apply_ops(rows, ops) do
    if valid?(ops) do
      %{reset?: reset?, deletes: deletes, inserts: inserts} = ops
      {removed, kept} = Enum.split_with(rows, fn {dom_id, _} -> reset? or dom_id in deletes end)
      inserts = Enum.filter(inserts, &valid_insert?/1)
      {rows, _removed} = Enum.reduce(inserts, {kept, Map.new(removed)}, &insert/2)
      rows
    else
      rows
    end
  end

  @doc """
  Whether `ops` has the shape `PhoenixReplay.Capture.Streams` records: a
  reset flag and lists of deletes and inserts. `apply/2` also skips
  inserts of any other shape.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%{reset?: reset?, deletes: deletes, inserts: inserts})
      when is_boolean(reset?) and is_list(deletes) and is_list(inserts),
      do: true

  def valid?(_ops), do: false

  defp valid_insert?(%{dom_id: dom_id, at: at, limit: limit, update_only: update_only, item: _})
       when is_binary(dom_id) and is_integer(at) and (is_integer(limit) or is_nil(limit)) and
              is_boolean(update_only),
       do: true

  defp valid_insert?(_insert), do: false

  defp insert(%{dom_id: dom_id, item: item} = insert, {rows, removed}) do
    case Enum.find_index(rows, &(elem(&1, 0) == dom_id)) do
      nil when insert.update_only and not is_map_key(removed, dom_id) ->
        {rows, removed}

      nil ->
        {kept, dropped} = rows |> List.insert_at(insert.at, {dom_id, item}) |> limit(insert.limit)
        {kept, Map.merge(removed, Map.new(dropped))}

      index ->
        {List.replace_at(rows, index, {dom_id, item}), removed}
    end
  end

  defp limit(rows, nil), do: {rows, []}
  defp limit(rows, limit) when limit >= 0, do: Enum.split(rows, limit)

  defp limit(rows, limit) do
    {dropped, kept} = Enum.split(rows, max(length(rows) + limit, 0))
    {kept, dropped}
  end
end
