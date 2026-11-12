defmodule PhoenixReplay.Recording.Streams do
  @moduledoc """
  The rows of recorded streams, rebuilt from the operations
  `PhoenixReplay.Capture.Streams` recorded, as LiveView's client applies
  them to the page:

    * a reset removes every row, then deletes remove rows by DOM id
    * an insert of a row already shown updates it in place
    * an insert with `update_only` changes only a row already shown
    * a new row goes at `at`: `-1` appends it, `0` prepends it, and `n`
      puts it at index `n`, or last when there are fewer rows
    * then a `limit` keeps the first `limit` rows, or the last `-limit`
      when negative

  `PhoenixReplay.Recording.Timeline` keeps the rows under the `:streams`
  key of a view's or component's assigns, which no assign can have,
  `%{name => [{dom_id, item}]}`, in the order the page shows them.
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
  def apply(streams, ops) do
    Enum.reduce(ops, streams, fn {name, ops}, acc ->
      Map.put(acc, name, apply_ops(Map.get(acc, name, []), ops))
    end)
  end

  defp apply_ops(rows, %{reset?: reset?, deletes: deletes, inserts: inserts}) do
    rows = if reset?, do: [], else: rows
    rows = Enum.reject(rows, fn {dom_id, _item} -> dom_id in deletes end)
    Enum.reduce(inserts, rows, &insert/2)
  end

  defp insert(%{dom_id: dom_id, item: item} = insert, rows) do
    case Enum.find_index(rows, &(elem(&1, 0) == dom_id)) do
      nil when insert.update_only -> rows
      nil -> rows |> List.insert_at(insert.at, {dom_id, item}) |> limit(insert.limit)
      index -> List.replace_at(rows, index, {dom_id, item})
    end
  end

  defp limit(rows, nil), do: rows
  defp limit(rows, limit), do: Enum.take(rows, limit)
end
