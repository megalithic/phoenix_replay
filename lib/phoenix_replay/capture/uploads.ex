defmodule PhoenixReplay.Capture.Uploads do
  @moduledoc """
  Takes the state of a LiveView's or LiveComponent's uploads, when
  `:uploads` is configured, so the replay can render their inputs and
  entries.

  Each upload is kept as `%{ref, accept, max_entries, max_file_size,
  auto_upload?, errors, entries}`, its entries as `%{ref, client_name,
  client_size, client_type, progress, preflighted?, valid?, done?,
  cancelled?}`. The refs are LiveView's random ids, which tie errors to the
  upload or the entry they belong to. The files' contents, the paths they
  were written to, the client's relative path and last-modified time, and
  the upload's callbacks are never taken.

  Each upload goes through `sanitize_assigns/1` of the session's
  `PhoenixReplay.Sanitizer` under its name, as an assign of that name
  would. A sanitizer that leaves that name out leaves the upload out.
  """

  alias Phoenix.LiveView.{UploadConfig, UploadEntry}

  @config [:ref, :accept, :max_entries, :max_file_size, :auto_upload?, :errors]
  @entry [
    :ref,
    :client_name,
    :client_size,
    :client_type,
    :progress,
    :preflighted?,
    :valid?,
    :done?,
    :cancelled?
  ]

  @doc "The state of each upload in `uploads`, a LiveView's `@uploads`, by name, sanitized."
  @spec state(map(), module()) :: %{(atom() | String.t()) => map()}
  def state(uploads, sanitizer) when is_map(uploads) do
    for {name, %UploadConfig{} = config} <- uploads,
        %{^name => %{} = upload} <- [sanitizer.sanitize_assigns(%{name => take(config)})],
        into: %{},
        do: {name, upload}
  end

  defp take(%UploadConfig{entries: entries} = config) do
    config
    |> Map.take(@config)
    |> Map.put(
      :entries,
      Enum.map(entries, fn %UploadEntry{} = entry -> Map.take(entry, @entry) end)
    )
  end
end
