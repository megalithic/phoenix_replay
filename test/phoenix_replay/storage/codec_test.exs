defmodule PhoenixReplay.Storage.CodecTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Recording
  alias PhoenixReplay.Recording.Client
  alias PhoenixReplay.Recording.Client.Landing
  alias PhoenixReplay.Recording.{Runtime, Summary, Value}
  alias PhoenixReplay.Storage.Codec
  alias PhoenixReplay.Test.Fixtures

  test "round-trips a recording" do
    recording = Fixtures.counter_recording()
    assert Codec.decode(Codec.encode(recording), Recording) == {:ok, recording}
  end

  test "stores node-bound values without introducing the recording node's atom" do
    name = "phoenix_replay_codec_#{System.unique_integer([:positive])}@nohost"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    script = """
    alias PhoenixReplay.Storage.Codec
    alias PhoenixReplay.Test.Fixtures

    values = %{
      pid: self(),
      reference: make_ref(),
      port: hd(Port.list()),
      local: fn -> self() end,
      external: &String.upcase/1
    }

    recording = Fixtures.counter_recording(clicks: 0)
    [mount, render] = recording.events
    recording = %{recording | events: [mount, put_in(render.data.assigns, values)]}
    <<131, encoded_node::binary>> = :erlang.term_to_binary(node())
    name = #{inspect(name)}

    raw =
      recording
      |> :erlang.term_to_binary()
      |> :binary.replace(encoded_node, <<119, byte_size(name), name::binary>>, [:global])

    recording = :erlang.binary_to_term(raw)
    result = {raw, Codec.encode(recording), IO.iodata_to_binary(Codec.frame(recording))}
    IO.write(Base.encode64(:erlang.term_to_binary(result)))
    """

    {output, 0} =
      System.cmd("elixir", ["-pa", Path.dirname(:code.which(Codec)), "-e", script],
        stderr_to_stdout: true
      )

    {raw, encoded, framed} = output |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    assert Codec.decode(raw, Recording) == {:error, :undecodable}
    assert_raise ArgumentError, fn -> :erlang.binary_to_term(raw, [:safe]) end

    assert {:ok, recording} = Codec.decode(encoded, Recording)
    assert :erlang.binary_to_term(encoded, [:safe]) == recording
    assert Codec.decode_frames(framed) == [recording]
    [_, render = %{data: %{assigns: values}}] = recording.events
    assert %Runtime{kind: :pid, inspect: "#PID<" <> _rest} = values.pid
    assert %Runtime{kind: :reference, inspect: "#Reference<" <> _rest} = values.reference
    assert %Runtime{kind: :port, inspect: "#Port<" <> _rest} = values.port
    assert %Runtime{kind: :function, inspect: "#Function<" <> _rest} = values.local
    assert values.external == (&String.upcase/1)

    [{"Assigns", highlighted}] = PhoenixReplay.Web.Player.Events.details(render)

    text =
      highlighted |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment() |> LazyHTML.text()

    assert text =~ inspect(values.pid)
    assert text =~ inspect(values.reference)
    refute text =~ "PhoenixReplay.Recording.Runtime"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "keeps runtime map keys and set members distinct from their literal strings" do
    pid = self()
    literal = inspect(pid)
    runtime = %Runtime{kind: :pid, inspect: literal}
    map = %{pid => :runtime, literal => :literal}
    set = MapSet.new([pid, literal])

    assert {:ok, [stored_map, stored_set]} = Codec.decode(Codec.encode([map, set]), :list)
    assert stored_map == %{runtime => :runtime, literal => :literal}
    assert stored_set == MapSet.new([runtime, literal])
    assert Value.inspect([runtime, literal]) == "[#{literal}, #{inspect(literal)}]"

    other = %{runtime | inspect: "#PID<0.1.0>"}

    assert PhoenixReplay.Recording.Diff.changes(runtime, other) == [
             {:changed, [], runtime, other}
           ]
  end

  test "fills fields added after the data was written" do
    written_by_older_version =
      %Summary{id: "a", view: "V", connected_at: 0}
      |> Map.from_struct()
      |> Map.delete(:event_names)
      |> Map.put(:__struct__, Summary)

    assert {:ok, %Summary{id: "a", event_names: []}} =
             written_by_older_version |> Codec.encode() |> Codec.decode(Summary)
  end

  test "brings the client context of a recording from before 0.6 up to date" do
    recording = Fixtures.counter_recording()

    stored_by_0_5 = %{
      recording
      | client: %{
          viewport: nil,
          user_agent: "Agent",
          tab: "t1",
          referer: "http://x/form",
          headers: %{},
          landing: %{path: "/", at: 1, params: %{}, referrer: nil}
        }
    }

    assert {:ok, %Recording{client: client}} =
             stored_by_0_5 |> Codec.encode() |> Codec.decode(Recording)

    assert client == %Client{
             user_agent: "Agent",
             tab: "t1",
             navigated_from: "http://x/form",
             landing: %Landing{path: "/", at: 1}
           }
  end

  test "decodes lists" do
    assert Codec.decode(Codec.encode(["a"]), :list) == {:ok, ["a"]}
    assert Codec.decode(Codec.encode(%{}), :list) == {:error, :undecodable}
  end

  test "rejects corrupt data, unknown atoms and other shapes" do
    assert Codec.decode("garbage", Recording) == {:error, :undecodable}

    unknown_atom = <<131, 119, 20, "phoenix_replay_nope_1">>
    assert Codec.decode(unknown_atom, Recording) == {:error, :undecodable}

    assert Codec.decode(Codec.encode(%{}), Recording) == {:error, :undecodable}

    assert Codec.decode(Codec.encode(Fixtures.counter_recording()), Summary) ==
             {:error, :undecodable}
  end

  test "frames survive appending and stop at a torn or corrupt frame" do
    binary =
      IO.iodata_to_binary([Codec.frame(:first), Codec.frame(%{second: [2]}), Codec.frame(3)])

    assert Codec.decode_frames(binary) == [:first, %{second: [2]}, 3]

    torn = binary_part(binary, 0, byte_size(binary) - 2)
    assert Codec.decode_frames(torn) == [:first, %{second: [2]}]

    second_payload_byte = byte_size(IO.iodata_to_binary(Codec.frame(:first))) + 12
    <<head::binary-size(^second_payload_byte), byte, rest::binary>> = binary
    assert Codec.decode_frames(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>) == [:first]

    assert Codec.decode_frames("") == []
  end
end
