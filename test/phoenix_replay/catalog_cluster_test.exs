defmodule PhoenixReplay.CatalogClusterTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixReplay.{Catalog, Config, Storage}
  alias PhoenixReplay.Recording.Filter
  alias PhoenixReplay.Session.Buffer
  alias PhoenixReplay.Test.{BlockingRedactor, Fixtures}

  @endpoint PhoenixReplay.Test.Endpoint
  @moduletag :cluster

  setup do
    {:ok, peer, other} =
      :peer.start_link(%{
        name: :"replay_catalog_#{System.unique_integer([:positive])}",
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    on_exit(fn -> catch_exit(:peer.stop(peer)) end)

    :ok =
      :erpc.call(other, Application, :put_all_env, [
        [phoenix_replay: Application.get_all_env(:phoenix_replay)]
      ])

    {:ok, _apps} = :erpc.call(other, Application, :ensure_all_started, [:phoenix_replay])
    %{peer: peer, other: other, config: Config.load()}
  end

  test "lists and plays a session buffered on another node", context do
    %{other: other, config: config} = context
    recording = %{Fixtures.counter_recording(id: "cluster-live") | url: "http://localhost/4242"}
    :ok = :erpc.call(other, Fixtures, :buffer_recording, [recording, [redact: ["4242"]]])
    filter = %Filter{query: "cluster-live"}
    now = System.system_time(:millisecond)

    assert [%{id: "cluster-live", live?: true, url: "http://localhost/[REDACTED]"}] =
             Catalog.live(filter, now)

    assert Catalog.live?(recording.id)
    assert Buffer.fetch(recording.id) == :error
    assert Storage.fetch(config.storage, recording.id) == {:error, :not_found}

    assert {:ok, redacted} =
             Catalog.fetch(config, recording.id, progress: Fixtures.progress(self()))

    assert redacted.url == "http://localhost/[REDACTED]"
    assert redacted.events == recording.events
    total = length(recording.events)
    assert_receive {:progress, ^total, ^total}

    {:ok, player, _html} = live(build_conn(), "/replay/cluster-live")
    assert render_async(player) =~ "PhoenixReplay.Test.Live.Counter"
    channel = :sys.get_state(player.pid).socket.assigns.channel
    {:ok, frame, html} = live(build_conn(), "/replay/cluster-live/frame?channel=#{channel}")
    assert html =~ "Redacting the session"
    assert has_element?(frame, "#count", "0")
    render_click(player, "seek", %{"index" => "5"})
    assert has_element?(frame, "#count", "2")
  end

  test "keeps local sessions visible when another node cannot serve its buffer", context do
    %{peer: peer, other: other, config: config} = context
    recording = Fixtures.counter_recording(id: "local-with-failed-peer")
    :ok = Buffer.open(recording, self(), config)
    on_exit(fn -> Buffer.close(recording.id) end)
    :ok = :erpc.call(other, Application, :stop, [:phoenix_replay])

    assert [%{id: "local-with-failed-peer"}] =
             Catalog.live(%Filter{query: recording.id}, System.system_time(:millisecond))

    refute Catalog.live?("missing-on-both-nodes")
    assert Catalog.fetch(config, "missing-on-both-nodes") == {:error, :not_found}

    :ok = :peer.stop(peer)

    assert [%{id: "local-with-failed-peer"}] =
             Catalog.live(%Filter{query: recording.id}, System.system_time(:millisecond))
  end

  test "stops remote discovery work when its summaries time out", context do
    %{other: other, config: config} = context
    recording = Fixtures.counter_recording(id: "slow-peer")

    :ok =
      :erpc.call(other, Fixtures, :buffer_recording, [
        recording,
        [redact: {BlockingRedactor, notify: self()}]
      ])

    local = Fixtures.counter_recording(id: "local-with-slow-peer")
    :ok = Buffer.open(local, self(), config)
    on_exit(fn -> Buffer.close(local.id) end)

    lookup =
      Task.async(fn ->
        Catalog.live(%Filter{query: local.id}, System.system_time(:millisecond))
      end)

    assert_receive {:redacting, worker}
    ref = Process.monitor(worker)
    assert [%{id: "local-with-slow-peer"}] = Task.await(lookup)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "allows a long remote completion but stops it when its caller exits", context do
    %{other: other, config: config} = context
    recording = Fixtures.counter_recording(id: "cancelled-completion")

    :ok =
      :erpc.call(other, Fixtures, :buffer_recording, [
        recording,
        [redact: {BlockingRedactor, notify: self()}]
      ])

    caller = spawn(fn -> Catalog.fetch(config, recording.id) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:redacting, worker}
    ref = Process.monitor(worker)
    refute_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_100
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  for failure <- [:kill, :exit, :throw] do
    test "falls back to storage when a remote completion fails with #{failure}", context do
      %{other: other, config: config} = context
      recording = Fixtures.counter_recording(id: "failed-completion-#{unquote(failure)}")
      :ok = Storage.save(config.storage, recording)
      on_exit(fn -> Storage.delete(config.storage, recording.id) end)

      :ok =
        :erpc.call(other, Fixtures, :buffer_recording, [
          recording,
          [redact: {BlockingRedactor, notify: self()}]
        ])

      lookup = Task.async(fn -> Catalog.fetch(config, recording.id) end)
      assert_receive {:redacting, worker}

      case unquote(failure) do
        :kill -> Process.exit(worker, :kill)
        kind -> send(worker, {kind, :failed})
      end

      assert Task.await(lookup) == {:ok, recording}
    end
  end
end
