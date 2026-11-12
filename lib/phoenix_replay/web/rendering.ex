defmodule PhoenixReplay.Web.Rendering do
  @moduledoc """
  Renders recorded views and LiveComponents with recorded assigns.

  Recorded templates are foreign code rendered with assigns that may be
  incomplete at a given position. HEEx evaluates assigns lazily while
  LiveView computes the diff, so `render_error/2` evaluates a template up
  front to report failures before LiveView sees them.

  `rewrite/2` replaces every LiveComponent in a rendered tree with
  `PhoenixReplay.Web.Live.ReplayComponent`, which renders the original
  module with the component's recorded assigns. Components need no changes
  to be replayed.

  `put_streams_and_uploads/2` gives a view or component the `@streams` and
  `@uploads` its template reads, rebuilt from the recording, which
  `assign/2` refuses to set. A stream or upload the recording lacks, as in
  one made without `:streams` or `:uploads`, renders empty; see
  `render_check/3`.
  """

  require Logger

  alias Phoenix.LiveView.{Component, Comprehension, LiveStream, Rendered, Socket}
  alias Phoenix.LiveView.{UploadConfig, UploadEntry}
  alias PhoenixReplay.Web.Live.ReplayComponent

  @type states :: %{{module(), term()} => map()}

  @typedoc """
  What a template reads that the recording lacks: an assign, or a stream
  or upload by name.
  """
  @type missing :: atom() | {:streams | :uploads, atom()}

  @typedoc "How a template rendered with recorded assigns; see `render_check/3`."
  @type check :: :ok | {:missing, missing()} | {:error, String.t()}

  @max_description 200
  # Assigns LiveView keeps for itself, which `assign/2` refuses.
  @reserved [:flash, :uploads, :streams, :socket, :myself]

  @doc """
  Renders a recorded view with `assigns`: with its `replay_render/1` when
  it defines one, with `render/1` otherwise, inside its layout, as
  LiveView renders it.

  `:layout` is the layout the recording kept, `PhoenixReplay.Recording`'s
  `layout`: a `{module, template}` pair of names, or `false` for none.
  Without it, as in recordings made before it was kept, the view renders
  in the layout its `use Phoenix.LiveView, layout: ...` names. A layout
  module that no longer exists is left out.

  `replay_render/1` is an optional callback for views whose live render
  depends on code in the browser, such as a client-side component whose
  state the server never sees. It receives the same assigns `render/1`
  would, plus the client state the browser reported up to this point in
  `PhoenixReplay.Recording.State.assign/0`, `%{key => merged changes}`,
  and returns a rendered template the replay frame can show without that
  code.

  It is rendered in full on every step, without change tracking: a view
  typically derives assigns from the reported state with `assign/3`, and
  tracking would compare them with the recorded assigns, not with the
  previous step, so a value that went back to what was recorded would stay
  stale on the page.
  """
  @spec render(module(), map(), keyword()) :: Phoenix.LiveView.Rendered.t()
  def render(view, assigns, opts \\ []) do
    loaded? = Code.ensure_loaded?(view)

    # The callback of PhoenixReplay.Replay.View is optional, so it is looked up.
    inner =
      if loaded? and function_exported?(view, :replay_render, 1),
        do: view.replay_render(Map.put(assigns, :__changed__, nil)),
        else: view.render(assigns)

    case layout(view, loaded?, Keyword.get(opts, :layout)) do
      {module, template} -> in_layout(inner, module, template, assigns)
      nil -> inner
    end
  end

  defp layout(_view, _loaded?, false), do: nil

  defp layout(_view, _loaded?, {module, template}) do
    module = String.to_existing_atom("Elixir." <> module)
    if Code.ensure_loaded?(module), do: {module, template}
  rescue
    # A layout module renamed or deleted since the session was recorded.
    ArgumentError -> nil
  end

  defp layout(view, loaded?, nil) do
    if loaded? and function_exported?(view, :__live__, 0) do
      case view.__live__()[:layout] do
        {module, template} -> {module, to_string(template)}
        _none -> nil
      end
    end
  end

  # As LiveView renders a view's layout: with the view as `@inner_content`.
  defp in_layout(inner, module, template, assigns) do
    assigns = Map.put(assigns, :inner_content, inner)

    # `replay_render/1` renders without change tracking, with `__changed__`
    # nil; only a tracked render marks the content as changed.
    assigns =
      if is_map(assigns[:__changed__]),
        do: put_in(assigns.__changed__[:inner_content], true),
        else: assigns

    Phoenix.Template.render(module, template, "html", assigns)
  end

  @doc """
  Renders `module` with `assigns`, returning a short description of the
  error when any part of the template fails to evaluate, or `nil`.

  Exception messages can include every assign, so the description names a
  missing assign or keeps the first line of the message; the full message
  is logged at the debug level.
  """
  @spec render_error(module(), map(), keyword()) :: String.t() | nil
  def render_error(module, assigns, opts \\ []),
    do: module |> render_check(assigns, opts) |> check_error()

  @doc "The short description of a failed `render_check/3`, or `nil` when it passed."
  @spec check_error(check()) :: String.t() | nil
  def check_error(:ok), do: nil
  def check_error({:missing, key}), do: "the recording has no #{name(key)}"
  def check_error({:error, description}), do: description

  @doc """
  How the player names what a template reads that the recording lacks:
  `@count`, `@streams.rows`.
  """
  @spec name(missing()) :: String.t()
  def name({kind, name}), do: "@#{kind}.#{name}"
  def name(key), do: "@#{key}"

  @doc """
  Renders `module` with `assigns`, as `render_error/2` does, telling an
  assign the recording lacks, such as one the template began to read after
  the session was recorded, from other failures: `{:missing, key}`, or
  `{:error, description}`. A stream or upload missing from the `@streams`
  or `@uploads` that `put_streams_and_uploads/2` set is
  `{:missing, {:streams | :uploads, name}}`. Takes `render/3`'s options.
  """
  @spec render_check(module(), map(), keyword()) :: check()
  # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
  def render_check(module, assigns, opts \\ []) do
    module |> render(assigns, opts) |> evaluate()
    :ok
  rescue
    # reach:disable-next-line bare_rescue -- recorded templates are foreign code rendered with partial assigns
    exception ->
      Logger.debug(
        "PhoenixReplay: #{inspect(module)} failed to render: #{Exception.message(exception)}"
      )

      case missing(exception, assigns) do
        nil -> {:error, describe(exception)}
        key -> {:missing, key}
      end
  end

  defp missing(%KeyError{key: key, term: %{__changed__: _changed}}, _assigns)
       when is_atom(key) and key not in @reserved,
       do: key

  defp missing(%KeyError{key: name, term: term}, assigns) when is_atom(name) and is_map(term) do
    cond do
      term == assigns[:streams] -> {:streams, name}
      term == assigns[:uploads] -> {:uploads, name}
      true -> nil
    end
  end

  defp missing(_exception, _assigns), do: nil

  @doc """
  Puts the `@streams` and `@uploads` of a replayed view or component into
  `socket_or_assigns`, built from the rows and upload state the timeline
  keeps under `:streams` and `:uploads` in its `recorded` assigns.

  Each stream shows exactly its recorded rows: it is reset and its rows
  inserted in order on every step, under a ref unique on the page. Each
  upload is a `Phoenix.LiveView.UploadConfig` with its recorded settings,
  entries and errors, which LiveView cannot upload to.

  `assign/2` refuses both keys, so they are put directly and marked
  changed, and left alone when they are the same as before. They are
  always put, empty without a recording of them, which lets
  `render_check/3` tell a stream or upload the recording lacks.
  """
  @spec put_streams_and_uploads(Socket.t() | map(), map()) :: Socket.t() | map()
  def put_streams_and_uploads(socket_or_assigns, recorded) do
    on_assigns(socket_or_assigns, fn assigns ->
      streams =
        Map.new(recorded[:streams] || %{}, fn {name, rows} ->
          {name, stream(assigns, name, rows)}
        end)

      uploads =
        Map.new(recorded[:uploads] || %{}, fn {name, upload} -> {name, upload(name, upload)} end)

      # LiveView finds an upload by the refs listed here: listing none, it
      # ignores the files a change in the replayed page sends.
      assigns
      |> put_reserved(:streams, streams)
      |> put_reserved(:uploads, Map.put(uploads, :__phoenix_refs_to_names__, %{}))
    end)
  end

  @doc """
  Puts an empty stream or upload in place of `missing`, one the template
  reads but `put_streams_and_uploads/2` found nothing recorded for.
  """
  @spec put_empty(Socket.t() | map(), {:streams | :uploads, atom()}) :: Socket.t() | map()
  def put_empty(socket_or_assigns, {kind, name}) do
    on_assigns(socket_or_assigns, fn assigns ->
      empty =
        case kind do
          :streams -> stream(assigns, name, [])
          :uploads -> %UploadConfig{name: name, ref: ref(assigns, name), accept: :any}
        end

      put_reserved(assigns, kind, Map.put(assigns[kind] || %{}, name, empty))
    end)
  end

  @doc """
  Checks that `module` renders with `assigns`, as `render_check/3` does,
  putting an empty stream or upload in place of each one the template
  reads and the recording lacks, with `put_empty/2`. Returns the assigns
  it rendered with and the last check.
  """
  @spec fill_streams_and_uploads(module(), map(), keyword()) :: {map(), check()}
  def fill_streams_and_uploads(module, assigns, opts \\ []) do
    case render_check(module, assigns, opts) do
      {:missing, {_kind, _name} = key} ->
        fill_streams_and_uploads(module, put_empty(assigns, key), opts)

      check ->
        {assigns, check}
    end
  end

  defp on_assigns(%Socket{assigns: assigns} = socket, fun), do: %{socket | assigns: fun.(assigns)}
  defp on_assigns(assigns, fun), do: fun.(assigns)

  defp put_reserved(assigns, key, value) do
    case assigns do
      %{^key => ^value} ->
        assigns

      %{__changed__: %{} = changed} ->
        assigns |> Map.put(key, value) |> Map.put(:__changed__, Map.put(changed, key, true))

      %{} ->
        Map.put(assigns, key, value)
    end
  end

  # A stream renders its inserts newest first, so the rows go in reversed.
  defp stream(assigns, name, rows) do
    inserts =
      Enum.reduce(rows, [], fn {dom_id, item}, acc -> [{dom_id, -1, item, nil, false} | acc] end)

    %LiveStream{name: name, ref: ref(assigns, name), inserts: inserts, reset?: true}
  end

  defp upload(name, upload) do
    entries =
      Enum.map(upload.entries, fn entry ->
        struct(UploadEntry, Map.merge(entry, %{upload_ref: upload.ref, upload_config: name}))
      end)

    %UploadConfig{
      name: name,
      ref: upload.ref,
      accept: upload.accept,
      max_entries: upload.max_entries,
      max_file_size: upload.max_file_size,
      auto_upload?: upload.auto_upload?,
      errors: upload.errors,
      entries: entries
    }
  end

  # Unique on the page, as LiveView's own: a component's carry its cid.
  defp ref(%{myself: %{cid: cid}}, name), do: "phx-replay-#{cid}-#{name}"
  defp ref(_assigns, name), do: "phx-replay-#{name}"

  @doc """
  Describes why a recorded template failed to render, in a line short
  enough for the player: a missing assign is named as such.
  """
  @spec describe(Exception.t()) :: String.t()
  def describe(%KeyError{key: key, term: %{__changed__: _changed}}) when is_atom(key),
    do: "the recording has no @#{key}"

  def describe(%KeyError{key: key}), do: "key #{inspect(key)} not found"

  def describe(exception) do
    line = exception |> Exception.message() |> String.split("\n", parts: 2) |> hd()

    if String.length(line) > @max_description,
      do: String.slice(line, 0, @max_description) <> "…",
      else: line
  end

  @doc "Leaves out of recorded `assigns` those LiveView keeps for itself."
  @spec assignable(map()) :: map()
  def assignable(assigns), do: Map.drop(assigns, @reserved)

  @doc "Routes every LiveComponent in `rendered` through the replay component."
  @spec rewrite(Rendered.t(), states()) :: Rendered.t()
  def rewrite(%Rendered{dynamic: dynamic} = rendered, states) do
    %{
      rendered
      | dynamic: fn track? -> Enum.map(dynamic.(track?), &rewrite_dynamic(&1, states)) end
    }
  end

  defp rewrite_dynamic(%Rendered{} = rendered, states), do: rewrite(rendered, states)

  defp rewrite_dynamic(%Comprehension{entries: entries} = comprehension, states) do
    entries =
      Enum.map(entries, fn {key, vars, render} ->
        {key, vars,
         fn vars_changed, track? ->
           Enum.map(render.(vars_changed, track?), &rewrite_dynamic(&1, states))
         end}
      end)

    %{comprehension | entries: entries}
  end

  defp rewrite_dynamic(%Component{component: ReplayComponent} = component, _states), do: component

  defp rewrite_dynamic(%Component{component: module, id: id, assigns: assigns}, states) do
    %Component{
      component: ReplayComponent,
      id: {module, id},
      assigns: Map.merge(assigns, ReplayComponent.replay_assigns(module, id, states))
    }
  end

  defp rewrite_dynamic(dynamic, _states), do: dynamic

  defp evaluate(%Rendered{dynamic: dynamic}), do: Enum.each(dynamic.(false), &evaluate/1)

  defp evaluate(%Comprehension{entries: entries}) do
    Enum.each(entries, fn {_key, _vars, render} ->
      Enum.each(render.(%{}, false), &evaluate/1)
    end)
  end

  defp evaluate(_dynamic), do: :ok
end
