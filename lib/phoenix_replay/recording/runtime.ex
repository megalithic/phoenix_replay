defmodule PhoenixReplay.Recording.Runtime do
  @moduledoc """
  A node-bound value kept only for display in a saved recording.

  Its kind and inspected representation survive storage without referring
  to the node that made it. Inspection displays the original representation,
  while the struct keeps it distinct from a literal string with that text.
  """

  @enforce_keys [:kind, :inspect]
  defstruct [:kind, :inspect]

  @type t :: %__MODULE__{
          kind: :pid | :port | :reference | :function,
          inspect: String.t()
        }
end

defimpl Inspect, for: PhoenixReplay.Recording.Runtime do
  @impl true
  def inspect(%{inspect: inspected}, _opts), do: inspected
end
