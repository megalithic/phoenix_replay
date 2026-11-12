defmodule PhoenixReplay.Recording.StreamsTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Recording.Streams

  defp ops(inserts, opts \\ []) do
    %{
      reset?: Keyword.get(opts, :reset?, false),
      deletes: Keyword.get(opts, :deletes, []),
      inserts:
        Enum.map(inserts, fn {dom_id, insert_opts} ->
          %{
            dom_id: dom_id,
            at: Keyword.get(insert_opts, :at, -1),
            limit: Keyword.get(insert_opts, :limit),
            update_only: Keyword.get(insert_opts, :update_only, false),
            item: Keyword.get(insert_opts, :item, dom_id)
          }
        end)
    }
  end

  defp rows(steps) do
    %{rows: rows} = Enum.reduce(steps, %{}, &Streams.apply(&2, %{rows: &1}))
    Enum.map(rows, fn {dom_id, _item} -> dom_id end)
  end

  defp items(steps) do
    %{rows: rows} = Enum.reduce(steps, %{}, &Streams.apply(&2, %{rows: &1}))
    rows
  end

  test "appends, prepends and inserts new rows at an index" do
    assert rows([ops([{"a", []}, {"b", []}])]) == ~w(a b)
    assert rows([ops([{"a", []}, {"b", []}]), ops([{"c", at: 0}])]) == ~w(c a b)
    assert rows([ops([{"a", []}, {"b", []}]), ops([{"c", at: 1}])]) == ~w(a c b)
    # Past the end, a row goes last.
    assert rows([ops([{"a", []}]), ops([{"c", at: 5}])]) == ~w(a c)
    # Rows inserted at 0 in one render each go first, so the last leads.
    assert rows([ops([{"a", at: 0}, {"b", at: 0}])]) == ~w(b a)
  end

  test "updates a row already shown in place, wherever it is inserted" do
    steps = [
      ops([{"a", []}, {"b", []}]),
      ops([{"a", at: 0, item: "A"}, {"b", at: -1, item: "B"}])
    ]

    assert items(steps) == [{"a", "A"}, {"b", "B"}]
  end

  test "an update_only insert changes only a row already shown" do
    steps = [
      ops([{"a", []}]),
      ops([{"a", update_only: true, item: "A"}, {"b", update_only: true}])
    ]

    assert items(steps) == [{"a", "A"}]
  end

  test "an update_only insert puts back a row the same render reset or deleted" do
    # The browser keeps a removed row the render inserts again, update_only or not.
    shown = ops([{"a", []}, {"b", []}])

    assert items([shown, ops([{"a", update_only: true, item: "A"}], reset?: true)]) ==
             [{"a", "A"}]

    assert items([shown, ops([{"a", update_only: true, item: "A"}], deletes: ["a"])]) ==
             [{"b", "b"}, {"a", "A"}]

    # A row that was not shown stays out.
    assert items([shown, ops([{"c", update_only: true}], deletes: ["c"])]) ==
             [{"a", "a"}, {"b", "b"}]
  end

  test "a positive limit keeps the first rows, a negative one the last" do
    assert rows([ops([{"a", []}, {"b", []}]), ops([{"c", at: 0, limit: 2}])]) == ~w(c a)
    assert rows([ops([{"a", []}, {"b", []}]), ops([{"c", limit: -2}])]) == ~w(b c)
    # Prepending under a negative limit drops the new row itself, as on the page.
    assert rows([ops([{"a", []}, {"b", []}]), ops([{"c", at: 0, limit: -2}])]) == ~w(a b)
    # An update keeps the rows as they are.
    assert rows([ops([{"a", []}, {"b", []}, {"c", []}]), ops([{"a", limit: 1}])]) == ~w(a b c)
  end

  test "deletes rows by DOM id, before the render's inserts" do
    assert rows([ops([{"a", []}, {"b", []}]), ops([], deletes: ["a", "x"])]) == ~w(b)
    assert rows([ops([{"a", []}]), ops([{"a", item: "again"}], deletes: ["a"])]) == ~w(a)
  end

  test "a reset removes every row before the render's inserts" do
    steps = [ops([{"a", []}, {"b", []}]), ops([{"c", []}, {"a", []}], reset?: true)]
    assert rows(steps) == ~w(c a)
    assert rows([ops([{"a", []}]), ops([], reset?: true)]) == []
  end

  test "keeps each stream apart, and a stream defined empty" do
    streams = Streams.apply(%{}, %{rows: ops([{"a", []}]), notes: ops([])})
    streams = Streams.apply(streams, %{notes: ops([{"n", []}])})
    assert streams == %{rows: [{"a", "a"}], notes: [{"n", "n"}]}
  end
end
