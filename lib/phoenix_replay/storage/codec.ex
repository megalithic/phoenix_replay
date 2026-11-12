defmodule PhoenixReplay.Storage.Codec do
  @moduledoc """
  Binary encoding shared by the storage backends.

  Terms are stored in compressed Erlang External Term Format, which keeps
  structs, atoms and tuples intact. Node-bound values become
  `PhoenixReplay.Recording.Runtime` structs, and regexes keep their source
  and options without their compiled pattern, so recordings can be read on
  nodes that never knew the recording node. These values are for display,
  not execution during replay.

  Decoding uses `:safe` mode, so a recording that references atoms this node
  has never seen fails to decode instead of growing the atom table.
  """

  alias PhoenixReplay.Recording
  alias PhoenixReplay.Recording.{Runtime, Summary}

  @frame_marker "PRF1"

  @doc """
  Encodes a term without node-bound runtime state.

  Pids, ports, references and local functions become
  `PhoenixReplay.Recording.Runtime` structs, including in map keys, so they
  stay distinct from literal strings with the same inspected text. Distinct
  local functions with identical inspected representations can still
  collapse as map keys or set members.

  External functions are kept. Regexes retain their fields except
  `re_pattern`, which becomes `nil`: templates can display their source and
  options, but cannot run the recorded regex.

  Maps, structs, lists and tuples are walked once, keeping unchanged
  branches rather than rebuilding them.
  """
  @spec encode(term()) :: binary()
  def encode(term) do
    {term, _changed?} = portable(term)
    :erlang.term_to_binary(term, compressed: 6)
  end

  defp portable(term) when is_pid(term), do: {%Runtime{kind: :pid, inspect: inspect(term)}, true}

  defp portable(term) when is_port(term),
    do: {%Runtime{kind: :port, inspect: inspect(term)}, true}

  defp portable(term) when is_reference(term),
    do: {%Runtime{kind: :reference, inspect: inspect(term)}, true}

  defp portable(term) when is_function(term) do
    case :erlang.fun_info(term, :type) do
      {:type, :external} -> {term, false}
      {:type, :local} -> {%Runtime{kind: :function, inspect: inspect(term)}, true}
    end
  end

  defp portable(%Regex{} = regex),
    do: {%{regex | re_pattern: nil}, not is_nil(regex.re_pattern)}

  defp portable(map) when is_map(map) do
    :maps.fold(
      fn key, value, {acc, changed?} ->
        {new_key, key_changed?} = portable(key)
        {new_value, value_changed?} = portable(value)

        cond do
          key_changed? -> {acc |> Map.delete(key) |> Map.put(new_key, new_value), true}
          value_changed? -> {Map.put(acc, key, new_value), true}
          true -> {acc, changed?}
        end
      end,
      {map, false},
      map
    )
  end

  defp portable([head | tail] = list) do
    {head, head_changed?} = portable(head)
    {tail, tail_changed?} = portable(tail)

    if head_changed? or tail_changed?, do: {[head | tail], true}, else: {list, false}
  end

  defp portable(tuple) when is_tuple(tuple) do
    case tuple |> Tuple.to_list() |> portable() do
      {list, true} -> {List.to_tuple(list), true}
      {_list, false} -> {tuple, false}
    end
  end

  defp portable(term), do: {term, false}

  @doc """
  Decodes a binary produced by `encode/1` into a `struct` of the given
  module, or into a list when `shape` is `:list`.

  Structs are rebuilt with `struct/2`, so data written before a field was
  added gets the field's default, and recordings go through
  `PhoenixReplay.Recording.upgrade/1`.

  Recordings hold module names, such as the structs in assigns, and safe
  decoding refuses atoms the VM has not created yet. In development, where
  modules load on first use, a recording can name a module that exists but
  has not been loaded since the node started. The first time a binary does
  not decode, modules available on the code path but not yet loaded are
  loaded, which creates only the atoms of modules that really exist, and
  decoding is retried.

  Returns `{:error, :undecodable}` for corrupt data, atoms of no known
  module, or a term of a different shape.
  """
  @spec decode(binary(), module() | :list) :: {:ok, struct() | list()} | {:error, :undecodable}
  def decode(binary, shape) when is_binary(binary) and is_atom(shape) do
    with {:error, :undecodable} <- safe_decode(binary, shape),
         true <- load_available_modules() do
      safe_decode(binary, shape)
    else
      false -> {:error, :undecodable}
      decoded -> decoded
    end
  end

  defp safe_decode(binary, shape) do
    binary |> :erlang.binary_to_term([:safe]) |> shape(shape)
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  # Loads at most once per node; false when that already happened.
  defp load_available_modules do
    if :persistent_term.get({__MODULE__, :modules_loaded}, false) do
      false
    else
      for {name, _file, false} <- :code.all_available(),
          do: :code.ensure_loaded(List.to_atom(name))

      :persistent_term.put({__MODULE__, :modules_loaded}, true)
      true
    end
  end

  @doc """
  Encodes a term as a frame that can be appended to a file.

  A frame is a marker, the payload's byte size and CRC32, then the payload
  encoded by `encode/1`. `decode_frames/1` stops at the first frame that is
  cut short or fails its checksum, so a write torn by a crash loses only
  itself.
  """
  @spec frame(term()) :: iodata()
  def frame(term) do
    payload = encode(term)
    [@frame_marker, <<byte_size(payload)::32, :erlang.crc32(payload)::32>>, payload]
  end

  @doc """
  Decodes the frames at the start of `binary`, in order, stopping at the
  first incomplete or corrupt one.
  """
  @spec decode_frames(binary()) :: [term()]
  def decode_frames(binary) when is_binary(binary), do: decode_frames(binary, [])

  defp decode_frames(
         <<@frame_marker, size::32, crc::32, payload::binary-size(size), rest::binary>>,
         acc
       ) do
    with true <- :erlang.crc32(payload) == crc,
         {:ok, term} <- safe_decode(payload) do
      decode_frames(rest, [term | acc])
    else
      _corrupt -> Enum.reverse(acc)
    end
  end

  defp decode_frames(_rest, acc), do: Enum.reverse(acc)

  defp safe_decode(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp shape(term, :list) when is_list(term), do: {:ok, term}

  defp shape(%{__struct__: struct} = term, struct),
    do: {:ok, struct |> struct(Map.from_struct(term)) |> upgrade()}

  defp shape(_term, _shape), do: {:error, :undecodable}

  defp upgrade(%Recording{} = recording), do: Recording.upgrade(recording)
  defp upgrade(%Summary{} = summary), do: Summary.upgrade(summary)
  defp upgrade(term), do: term
end
