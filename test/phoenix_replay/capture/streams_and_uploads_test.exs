defmodule PhoenixReplay.Capture.StreamsAndUploadsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.LiveStream
  alias PhoenixReplay.Capture.Streams
  alias PhoenixReplay.Recording.Event
  alias PhoenixReplay.Sanitizer.Default
  alias PhoenixReplay.Session.Buffer
  alias PhoenixReplay.Storage
  alias PhoenixReplay.Recording.Timeline
  alias PhoenixReplay.Test.{Fixtures, Sessions, Tasks}
  alias PhoenixReplay.Test.Live.Notes

  @endpoint PhoenixReplay.Test.Endpoint

  setup context do
    on_exit(fn -> Storage.clear(Fixtures.storage()) end)
    Sessions.setup_sessions(context)
  end

  defp events(id) do
    {:ok, recording} = Buffer.fetch(id)
    recording.events
  end

  defp stage(sessions, path) do
    {:ok, view, _html, id} = Sessions.live(sessions, build_conn(), path)
    render_click(view, "prepend", %{"name" => "beta"})
    render_click(view, "remove", %{"id" => "alpha"})
    render_click(view, "reset", %{"name" => "zeta"})
    view |> element("#add-note") |> render_click(%{"text" => "one"})

    csv =
      file_input(view, "#upload", :csv, [%{name: "staff.csv", content: "a,b", type: "text/csv"}])

    {:ok, _reply} = preflight_upload(csv)
    events(id)
  end

  test "records what each render changed in streams, and uploads' state", %{sessions: sessions} do
    events = stage(sessions, "/streamed/staging")

    assert [
             %{reset?: false, deletes: [], inserts: [%{dom_id: "row-alpha", at: -1} = alpha]},
             %{inserts: [%{dom_id: "row-beta", at: 0, limit: nil, update_only: false}]},
             %{deletes: ["row-alpha"], inserts: []},
             %{reset?: true, deletes: [], inserts: [%{dom_id: "row-zeta"}]}
           ] = for(%Event{type: :render, data: %{streams: %{rows: ops}}} <- events, do: ops)

    assert alpha.item == %{id: "alpha", name: "alpha"}

    # A stream defined empty is recorded, so the replay knows it is empty.
    assert [
             %{inserts: []},
             %{inserts: [%{dom_id: "note-one", at: 0, limit: 2, item: %{text: "one"}}]}
           ] = for(%Event{type: :component, data: %{streams: %{notes: ops}}} <- events, do: ops)

    uploads = for %Event{type: :render, data: %{uploads: %{csv: csv}}} <- events, do: csv
    assert [%{accept: ".csv", max_entries: 2, entries: []}, %{entries: [entry]} = csv] = uploads

    assert entry == %{
             ref: entry.ref,
             client_name: "staff.csv",
             client_size: 3,
             client_type: "text/csv",
             progress: 0,
             preflighted?: true,
             valid?: true,
             done?: false,
             cancelled?: false
           }

    assert csv.errors == []

    assert [%{photo: %{accept: :any, max_entries: 3, entries: []}}] =
             for(%Event{type: :component, data: %{uploads: uploads}} <- events, do: uploads)
  end

  test "records a component's upload through preflight, progress and completion",
       %{sessions: sessions} do
    {:ok, view, _html, id} = Sessions.live(sessions, build_conn(), "/streamed/staging")

    photo =
      &file_input(view, "#photo-form", :photo, [
        %{name: &1, content: String.duplicate("x", 100), type: "image/png"}
      ])

    # LiveView applies them to the component without the telemetry the
    # recorder listens to; the renders that follow are snapshotted.
    entries = fn ->
      render(view)
      Tasks.await()
      {:ok, recording} = Buffer.fetch(id)
      timeline = Timeline.at(recording, Timeline.last_index(recording))
      %{uploads: %{photo: %{entries: entries}}} = timeline.components[{Notes, "notes"}]
      Enum.map(entries, &Map.take(&1, [:client_name, :preflighted?, :progress, :done?]))
    end

    {:ok, _reply} = preflight_upload(photo.("cat.png"))
    cat = %{client_name: "cat.png", preflighted?: true, progress: 0, done?: false}
    assert entries.() == [cat]

    dog = photo.("dog.png")
    render_upload(dog, "dog.png", 50)
    assert [^cat, %{client_name: "dog.png", progress: 50, done?: false}] = entries.()

    render_upload(dog, "dog.png", 50)
    assert [^cat, %{client_name: "dog.png", progress: 100, done?: true}] = entries.()
  end

  test "records a stream an on_mount hook before the recorder defined", %{sessions: sessions} do
    {:ok, view, _html, id} = Sessions.live(sessions, build_conn(), "/hooked/staging")
    render_click(view, "append", %{"name" => "beta"})

    assert [%{notices: notices, rows: _alpha}, %{rows: beta}] =
             for(%Event{type: :render, data: %{streams: streams}} <- events(id), do: streams)

    assert %{inserts: [%{dom_id: "notices-1", item: %{text: "Welcome"}}]} = notices
    assert %{inserts: [%{dom_id: "row-beta"}]} = beta
  end

  test "records neither streams nor uploads by default", %{sessions: sessions} do
    events = stage(sessions, "/staging")

    refute Enum.any?(
             events,
             &(Map.has_key?(&1.data, :streams) or Map.has_key?(&1.data, :uploads))
           )

    refute Enum.any?(
             events,
             &match?(%Event{type: :render, data: %{assigns: assigns}} when assigns == %{}, &1)
           )
  end

  test "takes a stream's rows in render order, sanitized under its name" do
    rows = %LiveStream{
      name: :rows,
      inserts: [
        {"rows-2", 0, %{id: 2, name: "new", password: "b"}, nil, false},
        {"rows-1", -1, %{id: 1, password: "a"}, -10, nil},
        {"rows-2", -1, %{id: 2, name: "old", password: "old"}, 5, true}
      ],
      deletes: ["rows-0"]
    }

    tokens = %LiveStream{name: :tokens, inserts: [{"tokens-1", -1, %{id: 1}, nil, false}]}
    streams = %{__changed__: MapSet.new([:rows, :tokens]), __ref__: 2, rows: rows, tokens: tokens}

    # Inserted twice, a row renders once, in the order and with the item of
    # its last insert, and the browser places it as its first insert said.
    # The default sanitizer filters a value named like a token, which is
    # not a list of rows, so that stream is left out.
    assert Streams.pending(streams, Default) == %{
             rows: %{
               reset?: false,
               deletes: ["rows-0"],
               inserts: [
                 %{
                   dom_id: "rows-1",
                   at: -1,
                   limit: -10,
                   update_only: false,
                   item: %{id: 1, password: "[FILTERED]"}
                 },
                 %{
                   dom_id: "rows-2",
                   at: -1,
                   limit: 5,
                   update_only: true,
                   item: %{id: 2, name: "new", password: "[FILTERED]"}
                 }
               ]
             }
           }
  end
end
