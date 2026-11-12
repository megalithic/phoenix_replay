defmodule PhoenixReplay.Web.RenderingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixReplay.Web.Rendering

  defmodule Layouts do
    use Phoenix.Component

    def app(assigns) do
      ~H"""
      <nav>Menu</nav>
      <p :if={@flash["error"]} role="alert">{@flash["error"]}</p>
      {@inner_content}
      """
    end
  end

  defmodule LayoutView do
    use Phoenix.LiveView, layout: {Layouts, :app}

    def render(assigns), do: ~H"<main>{@count}</main>"
  end

  defmodule PlainView do
    use Phoenix.LiveView

    def render(assigns), do: ~H"<main>{@count}</main>"
  end

  test "renders a view in the layout its layout: option names, with the recorded flash" do
    assigns = %{__changed__: nil, count: 3, flash: %{"error" => "Below zero"}}
    html = LayoutView |> Rendering.render(assigns) |> rendered_to_string()

    assert html =~ "<nav>Menu</nav>"
    assert html =~ ~s(<p role="alert">Below zero</p>)
    assert html =~ "<main>3</main>"
  end

  test "renders a view without a layout option alone" do
    html = PlainView |> Rendering.render(%{__changed__: nil, count: 3}) |> rendered_to_string()
    assert html == "<main>3</main>"
  end

  test "prefers the layout the recording kept over the view's option" do
    assigns = %{__changed__: nil, count: 3, flash: %{}}
    recorded = {inspect(Layouts), "app"}

    assert PlainView
           |> Rendering.render(assigns, layout: recorded)
           |> rendered_to_string() =~ "<nav>Menu</nav>"

    # A mount that returned `layout: false` rendered the view alone live.
    assert LayoutView |> Rendering.render(assigns, layout: false) |> rendered_to_string() ==
             "<main>3</main>"
  end

  test "leaves out a recorded layout whose module no longer exists" do
    html =
      PlainView
      |> Rendering.render(%{__changed__: nil, count: 3}, layout: {"Gone.Layouts9f2c", "app"})
      |> rendered_to_string()

    assert html == "<main>3</main>"
  end

  test "describes a missing assign without dumping every assign" do
    assigns = %{__changed__: %{}, tasks: List.duplicate("task", 500)}

    assert Rendering.describe(%KeyError{key: :filter, term: assigns}) ==
             "the recording has no @filter"

    assert Rendering.describe(%KeyError{key: :name, term: %{other: 1}}) ==
             "key :name not found"
  end

  defmodule StreamView do
    use Phoenix.LiveView

    def render(assigns) do
      ~H"""
      <ul :for={i <- 1..30} id={"list-#{i}"} phx-update="stream">
        <li :for={{id, row} <- Map.fetch!(@streams, :"rows_#{i}")} id={id}>{row}</li>
      </ul>
      """
    end
  end

  test "gives the streams of the view and of each component refs no other stream has" do
    rows = [{"r-1", 1}]
    ref = &Rendering.put_streams_and_uploads(&1, %{streams: %{&2 => rows}}).streams[&2].ref

    refs = [
      ref.(%{__changed__: %{}}, :"1-rows"),
      ref.(%{__changed__: %{}}, :rows),
      ref.(%{__changed__: %{}}, "rows"),
      ref.(%{__changed__: %{}, myself: %{cid: 1}}, :rows),
      ref.(%{__changed__: %{}, myself: %{cid: 11}}, :rows),
      ref.(%{__changed__: %{}, myself: %{cid: 1}}, :"1-rows")
    ]

    assert Enum.uniq(refs) == refs
    assert Enum.all?(refs, &(&1 =~ ~r/^phx-replay-[\w-]+$/))
  end

  test "leaves out a recorded upload a sanitizer left without what an upload needs" do
    recorded = %{uploads: %{csv: %{entries: []}, photo: %{ref: "p", entries: [:not_an_entry]}}}
    assigns = Rendering.put_streams_and_uploads(%{__changed__: %{}}, recorded)

    assert assigns.uploads == %{__phoenix_refs_to_names__: %{}}
  end

  test "puts empty streams in place of missing ones, a bounded number of times" do
    assigns = Rendering.put_streams_and_uploads(%{__changed__: %{}}, %{})
    {assigns, check} = Rendering.fill_streams_and_uploads(StreamView, assigns)

    # The template reads more missing streams than a render fills.
    assert map_size(assigns.streams) == Rendering.max_filled()
    assert {:missing, {:streams, _name}} = check
  end

  test "keeps the first line of other messages, shortened" do
    assert Rendering.describe(%RuntimeError{message: "boom\nmore detail"}) == "boom"

    assert %RuntimeError{message: String.duplicate("x", 500)}
           |> Rendering.describe()
           |> String.length() == 201
  end
end
