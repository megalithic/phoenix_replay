defmodule PhoenixReplay.Recording.Label do
  @moduledoc """
  One-line descriptions of recorded events, as the player's event list and
  `PhoenixReplay.Trace` show them: `save → Cart#3: qty=2`, `navigate →
  /orders`, `assigns form, tasks`, a query's summary, a log's level and
  message. Streams read as the rows a render added and removed, such as
  `rows +2 −1`, and uploads by name, such as `upload avatar`.
  """

  alias PhoenixReplay.Recording.{Client, Event, State, Streams, Value}

  @doc "One line describing `event`, as the player's event list shows it."
  @spec of(Event.t()) :: String.t()
  def of(%Event{type: :mount}), do: "mount"

  # A form control's change reads as the control and its value; other
  # client state as its key and fields.
  def of(%Event{type: :state, data: %{key: key, changes: changes}}) do
    if key == State.inputs_key(),
      do: "input " <> Enum.map_join(changes, ", ", &input_label/1),
      else: "#{key}: " <> Enum.map_join(Enum.sort(changes), ", ", &field_label/1)
  end

  def of(%Event{type: :params, data: %{uri: uri}}), do: "navigate → #{uri}"
  def of(%Event{type: :info, data: %{tag: nil}}), do: "handle_info"
  def of(%Event{type: :info, data: %{tag: tag}}), do: "handle_info #{Value.inspect(tag)}"
  def of(%Event{type: :render, data: %{assigns: _assigns} = data}), do: changes_label(data)

  def of(%Event{type: :component, data: %{module: module, id: id} = data}),
    do: "#{component(module, id)} #{changes_label(data)}"

  def of(%Event{type: :component_destroyed, data: %{module: module, id: id}}),
    do: "#{component(module, id)} removed"

  def of(%Event{type: :telemetry, data: %{event: event} = data}) do
    label = data.summary || Enum.map_join(event, ".", &Atom.to_string/1)
    if data.error, do: "#{label} — #{data.error}", else: label
  end

  def of(%Event{type: :log, data: %{level: level, message: message}}),
    do: "[#{level}] #{message}"

  def of(%Event{type: :viewport, data: %{width: width, height: height} = viewport}),
    do: "viewport #{width} × #{height} #{Client.orientation(viewport)}"

  def of(%Event{type: :exit, data: %{reason: reason}}),
    do: "exited: " <> (reason |> String.split("\n", parts: 2) |> hd())

  def of(%Event{type: :event, data: %{name: name, params: params} = data}) do
    name =
      case data do
        %{target: {module, id}} -> "#{name} → #{component(module, id)}"
        %{} -> name
      end

    case params_line(params) do
      "" -> name
      label -> "#{name}: #{label}"
    end
  end

  @doc "A LiveComponent as `Module#id`."
  @spec component(module(), term()) :: String.t()
  def component(module, id) when is_binary(id), do: "#{inspect(module)}##{id}"
  def component(module, id), do: "#{inspect(module)}##{Value.inspect(id)}"

  defp changes_label(data) do
    assigns =
      case data[:assigns] do
        %{} = assigns when map_size(assigns) > 0 -> [assigns_label(assigns)]
        _none -> []
      end

    Enum.join(assigns ++ streams_and_uploads(data), ", ")
  end

  defp assigns_label(assigns) do
    "assigns " <> (assigns |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &to_string/1))
  end

  defp streams_and_uploads(data) do
    streams =
      for {name, ops} <- named(data[:streams]),
          Streams.valid?(ops),
          do: "#{name} #{stream_ops(ops)}"

    uploads = for {name, _upload} <- named(data[:uploads]), do: "upload #{name}"
    streams ++ uploads
  end

  @doc """
  The entries of a recorded map of streams or uploads with a usable name,
  see `PhoenixReplay.Recording.Streams.name?/1`, sorted by name; none when
  it is missing or malformed.
  """
  @spec named(term()) :: [{atom() | String.t(), term()}]
  def named(map) when is_non_struct_map(map),
    do: map |> Enum.filter(fn {name, _} -> Streams.name?(name) end) |> Enum.sort()

  def named(_other), do: []

  @doc """
  What a render did to one stream: `reset`, the rows it inserted or
  updated and those it deleted, as `reset +3`, `+2 −1` or, for a stream
  defined empty, `+0`.
  """
  @spec stream_ops(Streams.ops()) :: String.t()
  def stream_ops(%{reset?: reset?, inserts: inserts, deletes: deletes}) do
    [
      reset? && "reset",
      (inserts != [] or not (reset? or deletes != [])) && "+#{length(inserts)}",
      deletes != [] && "−#{length(deletes)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp params_line(params) do
    params
    |> params()
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{String.slice(value, 0, 40)}" end)
  end

  @doc """
  An event's params as name and value pairs, nested ones flattened, without
  LiveView's own (`_target`, `_unused_…`) or empty values.
  """
  @spec params(map()) :: [{String.t(), String.t()}]
  def params(params) do
    params
    |> Enum.reject(fn {key, _value} -> String.starts_with?(key, "_") end)
    |> Enum.flat_map(&flatten_param/1)
  end

  defp flatten_param({_key, %{} = nested}), do: Enum.flat_map(nested, &flatten_param/1)
  defp flatten_param({key, value}) when is_binary(value) and value != "", do: [{key, value}]
  defp flatten_param(_param), do: []

  defp input_label({selector, %{} = fields}),
    do: "#{selector} " <> Enum.map_join(fields, ", ", fn {_name, value} -> state_value(value) end)

  defp input_label({selector, _filtered}), do: selector

  defp field_label({field, value}), do: "#{field} #{state_value(value)}"

  defp state_value(value) when is_binary(value), do: inspect(String.slice(value, 0, 40))
  defp state_value(value), do: value |> Value.inspect(limit: 5) |> String.slice(0, 40)
end
