defmodule PhoenixReplay.Test.BlockingRedactor do
  @moduledoc "Redactor that waits for a test to let a remote lookup finish."

  @behaviour PhoenixReplay.Redactor

  @impl true
  def redact(text, opts) do
    send(Keyword.fetch!(opts, :notify), {:redacting, self()})

    receive do
      :continue -> {:ok, text}
    end
  end
end
