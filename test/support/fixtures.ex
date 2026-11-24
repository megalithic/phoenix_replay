defmodule PhoenixReplay.Test.Fixtures do
  @moduledoc "Builders for recordings used across tests."

  alias PhoenixReplay.Recording
  alias PhoenixReplay.Recording.Event

  @doc "Builds a recording of `PhoenixReplay.Test.Live.Counter` clicked `clicks` times."
  @spec counter_recording(keyword()) :: Recording.t()
  def counter_recording(opts \\ []) do
    clicks = Keyword.get(opts, :clicks, 2)

    events =
      Enum.flat_map(1..clicks//1, fn count ->
        [
          %Event{at: count * 1000, type: :event, data: %{name: "inc", params: %{}}},
          %Event{at: count * 1000 + 1, type: :render, data: %{assigns: %{count: count}}}
        ]
      end)

    %Recording{
      id: Keyword.get_lazy(opts, :id, &Recording.generate_id/0),
      view: PhoenixReplay.Test.Live.Counter,
      url: "http://localhost/counter",
      connected_at: Keyword.get(opts, :connected_at, System.system_time(:millisecond)),
      events:
        [
          %Event{at: 0, type: :mount, data: %{assigns: %{}}},
          %Event{at: 5, type: :render, data: %{assigns: %{count: 0}}}
        ] ++ events
    }
  end

  @doc "Buffers a recording on this node with the given configuration overrides."
  @spec buffer_recording(Recording.t(), keyword()) :: :ok
  def buffer_recording(recording, opts \\ []) do
    config = PhoenixReplay.Config.load(opts)
    pid = Process.whereis(PhoenixReplay.Supervisor)
    :ok = PhoenixReplay.Session.Buffer.open(recording, pid, config)

    for {event, seq} <- Enum.with_index(recording.events) do
      :ok = PhoenixReplay.Session.Buffer.append(recording.id, seq, event)
    end

    :ok
  end

  @doc "Reports redaction progress to a test, including when called on a peer node."
  @spec progress(pid()) :: PhoenixReplay.Redactor.progress()
  def progress(viewer), do: fn done, total -> send(viewer, {:progress, done, total}) end

  @doc "Returns the storage configured for the test environment."
  @spec storage() :: PhoenixReplay.Storage.t()
  def storage, do: PhoenixReplay.Config.load().storage
end
