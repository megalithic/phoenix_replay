defmodule PhoenixReplay.Catalog do
  @moduledoc """
  Reads and deletes recordings across the live buffer and storage.

  A recording is in exactly one place: `PhoenixReplay.Session.Buffer`
  on the node recording its session until it is saved, storage afterwards.
  Connected nodes are queried for buffered sessions, so a dashboard on any
  node can list and open them. Discovery waits up to one second and skips
  nodes that fail or do not answer. Nodes must share storage for saved recordings.
  Changes are broadcast on `PhoenixReplay.PubSub` so the dashboard can
  refresh without polling.

  Stored recordings were redacted when they were saved. Sessions still in
  the buffer are redacted here, with their session's `PhoenixReplay.Redactor`,
  so everything read through this module shows the same values.
  """

  alias PhoenixReplay.{Config, Recording, Redactor, Storage}
  alias PhoenixReplay.Session.{Buffer, Finalizer}
  alias PhoenixReplay.Recording.{Filter, Summary}

  @topic "phoenix_replay:recordings"
  @remote_timeout 1_000

  @doc "Lists buffered then stored recordings, each most recent first."
  @spec list(Config.t()) :: [Summary.t()]
  def list(%Config{storage: storage}) do
    buffered = buffered()
    buffered_ids = MapSet.new(buffered, & &1.id)
    buffered ++ Enum.reject(Storage.list(storage), &MapSet.member?(buffered_ids, &1.id))
  end

  @doc "Summaries of the sessions still recording that match `filter`, most recent first."
  @spec live(Filter.t(), integer()) :: [Summary.t()]
  def live(%Filter{} = filter, now) do
    buffered() |> Filter.select(filter, now)
  end

  @doc """
  Reads a page of stored recordings matching `filter`, most recent first,
  and counts every match. See `t:PhoenixReplay.Recording.Filter.page_opts/0`.

  Storage pages the recordings itself, unless `:allow` is given: a function
  that decides which summaries the reader may see. Every summary is then
  read and checked, so the count stays exact.
  """
  @spec query(Config.t(), Filter.t(), keyword()) :: {[Summary.t()], non_neg_integer()}
  def query(%Config{storage: storage}, %Filter{} = filter, opts) do
    case Keyword.pop(opts, :allow) do
      {nil, page_opts} ->
        Storage.query(storage, filter, page_opts)

      {allow, page_opts} ->
        storage |> Storage.list() |> Enum.filter(allow) |> Filter.page(filter, page_opts)
    end
  end

  @doc """
  The values of a filter's `field` among buffered and stored recordings
  matching the rest of `filter`, with how many recordings have each, the
  most common first, for suggesting filter values. Takes `:now`, `:limit`
  and `:allow` as `query/3` does.
  """
  @spec values(Config.t(), Filter.field(), Filter.t(), keyword()) ::
          [{String.t(), pos_integer()}]
  def values(%Config{storage: storage} = config, field, %Filter{} = filter, opts) do
    {now, limit} = {Keyword.fetch!(opts, :now), Keyword.fetch!(opts, :limit)}

    case Keyword.pop(opts, :allow) do
      {nil, page_opts} ->
        live = buffered() |> Filter.count_values(field, filter, now, limit)
        stored = Storage.values(storage, field, filter, page_opts)

        live
        |> Map.new()
        |> Map.merge(Map.new(stored), fn _value, a, b -> a + b end)
        |> Filter.top(limit)

      {allow, _page_opts} ->
        config |> list() |> Enum.filter(allow) |> Filter.count_values(field, filter, now, limit)
    end
  end

  @typedoc """
  How many sessions started in each stretch of a time range, for a chart:
  `buckets` are `{start, sessions, with_errors}`, every `size`
  milliseconds from `from` to `to`, empty ones included.
  """
  @type activity :: %{
          from: integer(),
          to: integer(),
          size: pos_integer(),
          buckets: [Filter.bucket() | {integer(), 0, 0}]
        }

  # Stretch lengths a chart picks from: the shortest that leaves at most
  # this many bars.
  @bucket_sizes Enum.map([1, 5, 15, 30, 60, 180, 360, 720, 1_440], &:timer.minutes/1)
  @longest_bucket :timer.hours(24 * 7)
  @max_buckets 40

  @doc """
  Counts the buffered and stored sessions matching `filter` by when they
  started, over the stretch of time it covers; see
  `PhoenixReplay.Recording.Filter.time_range/2`. Takes `:now` and
  `:allow` as `query/3` does, and `:utc_offset`, how far the viewer's
  time zone is ahead of UTC in milliseconds, so stretches begin at its
  midnights and hours.
  """
  @spec activity(Config.t(), Filter.t(), keyword()) :: activity()
  def activity(%Config{storage: storage} = config, %Filter{} = filter, opts) do
    now = Keyword.fetch!(opts, :now)
    {from, to} = Filter.time_range(filter, now)

    size =
      Enum.find(@bucket_sizes, @longest_bucket, &(div(to - from, &1) < @max_buckets))

    ranged = %{filter | within: nil, from: from, to: to}
    utc_offset = Keyword.get(opts, :utc_offset, 0)
    histogram_opts = [now: now, utc_offset: utc_offset]

    counts =
      case Keyword.get(opts, :allow) do
        nil ->
          buffered()
          |> Filter.histogram(ranged, size, histogram_opts)
          |> Enum.concat(Storage.histogram(storage, ranged, size, histogram_opts))

        allow ->
          config |> list() |> Enum.filter(allow) |> Filter.histogram(ranged, size, histogram_opts)
      end

    by_start =
      Enum.reduce(counts, %{}, fn {start, sessions, errors}, acc ->
        Map.update(acc, start, {sessions, errors}, fn {s, e} -> {s + sessions, e + errors} end)
      end)

    buckets =
      for start <-
            Filter.bucket(from, size, utc_offset)..Filter.bucket(to, size, utc_offset)//size do
        {sessions, errors} = Map.get(by_start, start, {0, 0})
        {start, sessions, errors}
      end

    %{from: from, to: to, size: size, buckets: buckets}
  end

  @doc """
  Fetches a recording from the buffer or storage.

  A buffered session is redacted first, which can take a while with a
  detecting `PhoenixReplay.Redactor`. Pass `progress: fun` to be called
  with the number of events redacted so far and the total. Completion runs
  on the node holding the buffer, including any chunks it flushed to storage.
  Remote completion has no time limit, as redaction can take a while, but
  stops if its caller exits or disconnects.
  """
  @spec fetch(Config.t(), Recording.id(), keyword()) :: {:ok, Recording.t()} | {:error, term()}
  def fetch(%Config{storage: storage}, id, opts \\ []) do
    with :error <- fetch_local(id, opts),
         :error <- fetch_remote(id, opts) do
      Storage.fetch(storage, id)
    end
  end

  @doc "Returns true while a connected node buffers the session `id`."
  @spec live?(Recording.id()) :: boolean()
  def live?(id), do: Buffer.config(id) != :error or owner(id) != nil

  @doc "Summaries buffered on this node, with URLs redacted by each session's redactor."
  @spec local_live() :: [Summary.t()]
  def local_live, do: Enum.map(Buffer.summaries(), &redact_url/1)

  @doc "Completes a recording buffered on this node, or returns `:error` if it is absent."
  @spec fetch_local(Recording.id(), keyword()) :: {:ok, Recording.t()} | {:error, term()} | :error
  def fetch_local(id, opts) do
    with {:ok, recording} <- Buffer.fetch(id),
         {:ok, config} <- Buffer.config(id) do
      Finalizer.complete(recording, config, Keyword.take(opts, [:progress]))
    end
  end

  defp buffered do
    remote = for {_node, summaries} <- remote_results(__MODULE__, :local_live, []), do: summaries

    (local_live() ++ List.flatten(remote))
    |> Enum.uniq_by(& &1.id)
    |> Summary.sort()
  end

  defp owner(id) do
    Enum.find_value(remote_results(Buffer, :config, [id]), fn
      {node, {:ok, _config}} -> node
      _missing -> nil
    end)
  end

  defp fetch_remote(id, opts) do
    case owner(id) do
      nil ->
        :error

      node ->
        :erpc.call(
          node,
          __MODULE__,
          :read_on_node,
          [self(), __MODULE__, :fetch_local, [id, opts], :infinity],
          :infinity
        )
    end
  rescue
    ErlangError -> :error
  catch
    :exit, {kind, _reason} when kind in [:exception, :signal] -> :error
    :throw, _reason -> :error
  end

  @doc """
  Runs a node-local read while its caller lives, for at most `timeout` milliseconds.

  `:infinity` allows a long completion. Unlike this owner-side bound,
  [`:erpc` timeouts](https://www.erlang.org/doc/apps/kernel/erpc.html#call/5)
  only stop waiting for a result; they do not stop the remote work.
  """
  @spec read_on_node(pid(), module(), atom(), [term()], timeout()) :: term()
  def read_on_node(caller, module, function, args, timeout) do
    worker = self()

    spawn(fn ->
      caller_ref = Process.monitor(caller)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^caller_ref, :process, ^caller, _reason} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
      after
        timeout -> Process.exit(worker, :kill)
      end
    end)

    apply(module, function, args)
  end

  defp remote_results(module, function, args) do
    case Node.list() do
      [] ->
        []

      nodes ->
        results =
          :erpc.multicall(
            nodes,
            __MODULE__,
            :read_on_node,
            [self(), module, function, args, @remote_timeout],
            @remote_timeout
          )

        for {node, {:ok, result}} <- Enum.zip(nodes, results), do: {node, result}
    end
  end

  @doc "Deletes a stored recording."
  @spec delete(Config.t(), Recording.id()) :: :ok | {:error, term()}
  def delete(%Config{storage: storage}, id) do
    with :ok <- Storage.delete(storage, id), do: broadcast_change()
  end

  @doc "Deletes every stored recording."
  @spec clear(Config.t()) :: :ok | {:error, term()}
  def clear(%Config{storage: storage}) do
    with :ok <- Storage.clear(storage), do: broadcast_change()
  end

  @doc "Subscribes the caller to `:recordings_changed` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, @topic)

  @doc "Notifies subscribers that the set of recordings changed."
  @spec broadcast_change() :: :ok
  def broadcast_change do
    Phoenix.PubSub.broadcast(PhoenixReplay.PubSub, @topic, :recordings_changed)
  end

  defp redact_url(%Summary{url: nil} = summary), do: summary

  defp redact_url(%Summary{id: id, url: url} = summary) do
    with {:ok, %Config{redact: redactor}} when redactor != nil <- Buffer.config(id),
         {:ok, url} <- Redactor.redact_term(url, redactor) do
      %{summary | url: url}
    else
      {:ok, %Config{redact: nil}} -> summary
      _failed -> %{summary | url: nil}
    end
  end
end
