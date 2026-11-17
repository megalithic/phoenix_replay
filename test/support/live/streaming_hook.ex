defmodule PhoenixReplay.Test.Live.StreamingHook do
  @moduledoc "`on_mount` hook that defines a stream before the recorder attaches."

  import Phoenix.LiveView, only: [stream: 3]

  @doc "Streams a notice into every view of its live session."
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket),
    do: {:cont, stream(socket, :notices, [%{id: 1, text: "Welcome"}])}
end
