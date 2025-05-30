defmodule Phoenix.Controller do
  import Plug.Conn
  alias Plug.Conn.AlreadySentError

  require Logger
  require Phoenix.Endpoint

  @unsent [:unset, :set, :set_chunked, :set_file]

  # View/Layout deprecation plan
  # 1. DONE! Deprecate :namespace option in favor of :layouts on use
  # 2. Deprecate the :layouts option in use Phoenix.Controller
  # 3. Deprecate setting a non-format view/layout on put_*
  # 4. Deprecate rendering a view/layout from :_

  @type view :: atom()
  @type layout :: {module(), layout_name :: atom()} | false

  @moduledoc """
  Controllers are used to group common functionality in the same
  (pluggable) module.

  For example, the route:

      get "/users/:id", MyAppWeb.UserController, :show

  will invoke the `show/2` action in the `MyAppWeb.UserController`:

      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def show(conn, %{"id" => id}) do
          user = Repo.get(User, id)
          render(conn, :show, user: user)
        end
      end

  An action is a regular function that receives the connection
  and the request parameters as arguments. The connection is a
  `Plug.Conn` struct, as specified by the Plug library.

  Then we invoke `render/3`, passing the connection, the template
  to render (typically named after the action), and the `user: user`
  as assigns. We will explore all of those concepts next.

  ## Connection

  A controller by default provides many convenience functions for
  manipulating the connection, rendering templates, and more.

  Those functions are imported from two modules:

    * `Plug.Conn` - a collection of low-level functions to work with
      the connection

    * `Phoenix.Controller` - functions provided by Phoenix
      to support rendering, and other Phoenix specific behaviour

  If you want to have functions that manipulate the connection
  without fully implementing the controller, you can import both
  modules directly instead of `use Phoenix.Controller`.

  ## Rendering

  One of the main features provided by controllers is the ability
  to perform content negotiation and render templates based on
  information sent by the client.

  There are two ways to render content in a controller. One option
  is to invoke format-specific functions, such as `html/2` and `json/2`.

  However, most commonly controllers invoke custom modules called
  views. Views are modules capable of rendering a custom format.
  This is done by specifying the option `:formats` when defining
  the controller:

      use Phoenix.Controller, formats: [:html, :json]

   Now, when invoking `render/3`, a controller named `MyAppWeb.UserController`
   will invoke `MyAppWeb.UserHTML` and `MyAppWeb.UserJSON` respectively
   when rendering each format:

      def show(conn, %{"id" => id}) do
        user = Repo.get(User, id)
        # Will invoke UserHTML.show(%{user: user}) for html requests
        # Will invoke UserJSON.show(%{user: user}) for json requests
        render(conn, :show, user: user)
      end

  You can also specify formats to render by calling `put_view/2`
  directly with a connection. For example, instead of inferring the
  the view names from the controller, as done in:

      use Phoenix.Controller, formats: [:html, :json]

  You can write the above explicitly in your actions as:

      put_view(conn, html: MyAppWeb.UserHTML, json: MyAppWeb.UserJSON)

  Or as a plug:

      plug :put_view, html: MyAppWeb.UserHTML, json: MyAppWeb.UserJSON

  ## Layouts

  Many applications have shared content that they want to include on every
  page, most often the `<head>` tag and its contents. In Phoenix, this is
  done via the `put_root_layout` function:

      put_root_layout(conn, html: {MyAppWeb.Layouts, :root})

  In most applications, this is invoked as a Plug in your application router:

      plug :put_root_layout, html: {MyAppWeb.Layouts, :root}

  This layout is shared by all controllers, and also by `Phoenix.LiveView`.

  However, you can also specify controller-specific layouts using `put_layout/2`,
  although this functionality is discouraged in Phoenix v1.8 in favor of using
  function components to build your application.

  ## Options

  When used, the controller supports the following options to customize
  template rendering:

    * `:formats` - the formats this controller will render
      by default. For example, specifying `formats: [:html, :json]`
      for a controller named `MyAppWeb.UserController` will
      invoke `MyAppWeb.UserHTML` and `MyAppWeb.UserJSON` when
      respectively rendering each format.

  The `:formats` option is required. You may set it to an empty list
  if you don't expect to render any format upfront. If `:formats` is not
  set, the default view is set to `MyAppWeb.UserView` for backwards
  compatibility. This behaviour can be explicitly retained by passing a
  suffix to the `:formats` option:

      use Phoenix.Controller, formats: [html: "View", json: "View"]

  ## Plug pipeline

  As with routers, controllers also have their own plug pipeline.
  However, different from routers, controllers have a single pipeline:

      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        plug :authenticate, usernames: ["jose", "eric", "sonny"]

        def show(conn, params) do
          # authenticated users only
        end

        defp authenticate(conn, options) do
          if get_session(conn, :username) in options[:usernames] do
            conn
          else
            conn |> redirect(to: "/") |> halt()
          end
        end
      end

  The `:authenticate` plug will be invoked before the action. If the
  plug calls `Plug.Conn.halt/1` (which is by default imported into
  controllers), it will halt the pipeline and won't invoke the action.

  ### Guards

  `plug/2` in controllers supports guards, allowing a developer to configure
  a plug to only run in some particular action.

      plug :do_something when action in [:show, :edit]

  Due to operator precedence in Elixir, if the second argument is a keyword list,
  we need to wrap the keyword in `[...]` when using `when`:

      plug :authenticate, [usernames: ["jose", "eric", "sonny"]] when action in [:show, :edit]
      plug :authenticate, [usernames: ["admin"]] when not action in [:index]

  The first plug will run only when action is show or edit. The second plug will
  always run, except for the index action.

  Those guards work like regular Elixir guards and the only variables accessible
  in the guard are `conn`, the `action` as an atom and the `controller` as an
  alias.

  ## Controllers are plugs

  Like routers, controllers are plugs, but they are wired to dispatch
  to a particular function which is called an action.

  For example, the route:

      get "/users/:id", UserController, :show

  will invoke `UserController` as a plug:

      UserController.call(conn, :show)

  which will trigger the plug pipeline and which will eventually
  invoke the inner action plug that dispatches to the `show/2`
  function in `UserController`.

  As controllers are plugs, they implement both [`init/1`](`c:Plug.init/1`) and
  [`call/2`](`c:Plug.call/2`), and it also provides a function named `action/2`
  which is responsible for dispatching the appropriate action
  after the plug stack (and is also overridable).

  ### Overriding `action/2` for custom arguments

  Phoenix injects an `action/2` plug in your controller which calls the
  function matched from the router. By default, it passes the conn and params.
  In some cases, overriding the `action/2` plug in your controller is a
  useful way to inject arguments into your actions that you would otherwise
  need to repeatedly fetch off the connection. For example, imagine if you
  stored a `conn.assigns.current_user` in the connection and wanted quick
  access to the user for every action in your controller:

      def action(conn, _) do
        args = [conn, conn.params, conn.assigns.current_user]
        apply(__MODULE__, action_name(conn), args)
      end

      def index(conn, _params, user) do
        videos = Repo.all(user_videos(user))
        # ...
      end

      def delete(conn, %{"id" => id}, user) do
        video = Repo.get!(user_videos(user), id)
        # ...
      end

  """
  defmacro __using__(opts) do
    opts =
      if Macro.quoted_literal?(opts) do
        Macro.prewalk(opts, &expand_alias(&1, __CALLER__))
      else
        opts
      end

    quote bind_quoted: [opts: opts] do
      import Phoenix.Controller
      import Plug.Conn

      use Phoenix.Controller.Pipeline

      with {layout, view} <- Phoenix.Controller.__plugs__(__MODULE__, opts) do
        plug :put_new_layout, layout
        plug :put_new_view, view
      end
    end
  end

  defp expand_alias({:__aliases__, _, _} = alias, env),
    do: Macro.expand(alias, %{env | function: {:action, 2}})

  defp expand_alias(other, _env), do: other

  @doc """
  Registers the plug to call as a fallback to the controller action.

  A fallback plug is useful to translate common domain data structures
  into a valid `%Plug.Conn{}` response. If the controller action fails to
  return a `%Plug.Conn{}`, the provided plug will be called and receive
  the controller's `%Plug.Conn{}` as it was before the action was invoked
  along with the value returned from the controller action.

  ## Examples

      defmodule MyController do
        use Phoenix.Controller

        action_fallback MyFallbackController

        def show(conn, %{"id" => id}, current_user) do
          with {:ok, post} <- Blog.fetch_post(id),
               :ok <- Authorizer.authorize(current_user, :view, post) do

            render(conn, "show.json", post: post)
          end
        end
      end

  In the above example, `with` is used to match only a successful
  post fetch, followed by valid authorization for the current user.
  In the event either of those fail to match, `with` will not invoke
  the render block and instead return the unmatched value. In this case,
  imagine `Blog.fetch_post/2` returned `{:error, :not_found}` or
  `Authorizer.authorize/3` returned `{:error, :unauthorized}`. For cases
  where these data structures serve as return values across multiple
  boundaries in our domain, a single fallback module can be used to
  translate the value into a valid response. For example, you could
  write the following fallback controller to handle the above values:

      defmodule MyFallbackController do
        use Phoenix.Controller

        def call(conn, {:error, :not_found}) do
          conn
          |> put_status(:not_found)
          |> put_view(MyErrorView)
          |> render(:"404")
        end

        def call(conn, {:error, :unauthorized}) do
          conn
          |> put_status(:forbidden)
          |> put_view(MyErrorView)
          |> render(:"403")
        end
      end
  """
  defmacro action_fallback(plug) do
    Phoenix.Controller.Pipeline.__action_fallback__(plug, __CALLER__)
  end

  @doc """
  Returns the action name as an atom, raises if unavailable.
  """
  @spec action_name(Plug.Conn.t()) :: atom
  def action_name(conn), do: conn.private.phoenix_action

  @doc """
  Returns the controller module as an atom, raises if unavailable.
  """
  @spec controller_module(Plug.Conn.t()) :: atom
  def controller_module(conn), do: conn.private.phoenix_controller

  @doc """
  Returns the router module as an atom, raises if unavailable.
  """
  @spec router_module(Plug.Conn.t()) :: atom
  def router_module(conn), do: conn.private.phoenix_router

  @doc """
  Returns the endpoint module as an atom, raises if unavailable.
  """
  @spec endpoint_module(Plug.Conn.t()) :: atom
  def endpoint_module(conn), do: conn.private.phoenix_endpoint

  @doc """
  Returns the template name rendered in the view as a string
  (or nil if no template was rendered).
  """
  @spec view_template(Plug.Conn.t()) :: binary | nil
  def view_template(conn) do
    conn.private[:phoenix_template]
  end

  @doc """
  Sends JSON response.

  It uses the configured `:json_library` under the `:phoenix`
  application for `:json` to pick up the encoder module.

  ## Examples

      iex> json(conn, %{id: 123})

  """
  @spec json(Plug.Conn.t(), term) :: Plug.Conn.t()
  def json(conn, data) do
    response = Phoenix.json_library().encode_to_iodata!(data)
    send_resp(conn, conn.status || 200, "application/json", response)
  end

  @doc """
  A plug that may convert a JSON response into a JSONP one.

  In case a JSON response is returned, it will be converted
  to a JSONP as long as the callback field is present in
  the query string. The callback field itself defaults to
  "callback", but may be configured with the callback option.

  In case there is no callback or the response is not encoded
  in JSON format, it is a no-op.

  Only alphanumeric characters and underscore are allowed in the
  callback name. Otherwise an exception is raised.

  ## Examples

      # Will convert JSON to JSONP if callback=someFunction is given
      plug :allow_jsonp

      # Will convert JSON to JSONP if cb=someFunction is given
      plug :allow_jsonp, callback: "cb"

  """
  @spec allow_jsonp(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def allow_jsonp(conn, opts \\ []) do
    callback = Keyword.get(opts, :callback, "callback")

    case Map.fetch(conn.query_params, callback) do
      :error ->
        conn

      {:ok, ""} ->
        conn

      {:ok, cb} ->
        validate_jsonp_callback!(cb)

        register_before_send(conn, fn conn ->
          if json_response?(conn) do
            conn
            |> put_resp_header("content-type", "application/javascript")
            |> resp(conn.status, jsonp_body(conn.resp_body, cb))
          else
            conn
          end
        end)
    end
  end

  defp json_response?(conn) do
    case get_resp_header(conn, "content-type") do
      ["application/json;" <> _] -> true
      ["application/json"] -> true
      _ -> false
    end
  end

  defp jsonp_body(data, callback) do
    body =
      data
      |> IO.iodata_to_binary()
      |> String.replace(<<0x2028::utf8>>, "\\u2028")
      |> String.replace(<<0x2029::utf8>>, "\\u2029")

    "/**/ typeof #{callback} === 'function' && #{callback}(#{body});"
  end

  defp validate_jsonp_callback!(<<h, t::binary>>)
       when h in ?0..?9 or h in ?A..?Z or h in ?a..?z or h == ?_,
       do: validate_jsonp_callback!(t)

  defp validate_jsonp_callback!(<<>>), do: :ok

  defp validate_jsonp_callback!(_),
    do: raise(ArgumentError, "the JSONP callback name contains invalid characters")

  @doc """
  Sends text response.

  ## Examples

      iex> text(conn, "hello")

      iex> text(conn, :implements_to_string)

  """
  @spec text(Plug.Conn.t(), String.Chars.t()) :: Plug.Conn.t()
  def text(conn, data) do
    send_resp(conn, conn.status || 200, "text/plain", to_string(data))
  end

  @doc """
  Sends html response.

  ## Examples

      iex> html(conn, "<html><head>...")

  """
  @spec html(Plug.Conn.t(), iodata) :: Plug.Conn.t()
  def html(conn, data) do
    send_resp(conn, conn.status || 200, "text/html", data)
  end

  @doc """
  Sends redirect response to the given url.

  For security, `:to` only accepts paths. Use the `:external`
  option to redirect to any URL.

  The response will be sent with the status code defined within
  the connection, via `Plug.Conn.put_status/2`. If no status
  code is set, a 302 response is sent.

  ## Examples

      iex> redirect(conn, to: "/login")

      iex> redirect(conn, external: "https://elixir-lang.org")

  """
  def redirect(conn, opts) when is_list(opts) do
    url = url(opts)
    html = Plug.HTML.html_escape(url)
    body = "<html><body>You are being <a href=\"#{html}\">redirected</a>.</body></html>"

    conn
    |> put_resp_header("location", url)
    |> send_resp(conn.status || 302, "text/html", body)
  end

  defp url(opts) do
    cond do
      to = opts[:to] -> validate_local_url(to)
      external = opts[:external] -> external
      true -> raise ArgumentError, "expected :to or :external option in redirect/2"
    end
  end

  @invalid_local_url_chars ["\\", "/%09", "/\t"]
  defp validate_local_url("//" <> _ = to), do: raise_invalid_url(to)

  defp validate_local_url("/" <> _ = to) do
    if String.contains?(to, @invalid_local_url_chars) do
      raise ArgumentError, "unsafe characters detected for local redirect in URL #{inspect(to)}"
    else
      to
    end
  end

  defp validate_local_url(to), do: raise_invalid_url(to)

  @spec raise_invalid_url(term()) :: no_return()
  defp raise_invalid_url(url) do
    raise ArgumentError, "the :to option in redirect expects a path but was #{inspect(url)}"
  end

  @doc """
  Stores the view for rendering.

  Raises `Plug.Conn.AlreadySentError` if `conn` is already sent.

  ## Examples

      iex> put_view(conn, html: AppHTML, json: AppJSON)

  """
  @spec put_view(Plug.Conn.t(), [{format :: atom, view}] | view) :: Plug.Conn.t()
  def put_view(%Plug.Conn{state: state} = conn, formats) when state in @unsent do
    put_private_view(conn, :phoenix_view, :replace, formats)
  end

  def put_view(%Plug.Conn{} = conn, module) do
    raise(AlreadySentError, """
    the response was already sent.

        Status code: #{conn.status}
        Request path: #{conn.request_path}
        Method: #{conn.method}
        View module: #{inspect(module)}
    """)
  end

  defp put_private_view(conn, priv_key, kind, formats) when is_list(formats) do
    formats = Enum.into(formats, %{}, fn {format, value} -> {to_string(format), value} end)
    put_private_formats(conn, priv_key, kind, formats)
  end

  # TODO: Deprecate this whole branch on Phoenix v1.9
  defp put_private_view(conn, priv_key, kind, value) do
    put_private_formats(conn, priv_key, kind, %{_: value})
  end

  defp put_private_formats(conn, priv_key, kind, formats) when kind in [:new, :replace] do
    update_in(conn.private, fn private ->
      existing = Map.get(private, priv_key, %{})

      new_formats =
        case kind do
          :new -> Map.merge(formats, existing)
          :replace -> Map.merge(existing, formats)
        end

      Map.put(private, priv_key, new_formats)
    end)
  end

  @doc """
  Stores the view for rendering if one was not stored yet.

  Raises `Plug.Conn.AlreadySentError` if `conn` is already sent.
  """
  # TODO: Remove | view from the spec once we deprecate put_new_view on controllers on v1.9
  @spec put_new_view(Plug.Conn.t(), [{format :: atom, view}] | view) :: Plug.Conn.t()
  def put_new_view(%Plug.Conn{state: state} = conn, formats) when state in @unsent do
    put_private_view(conn, :phoenix_view, :new, formats)
  end

  def put_new_view(%Plug.Conn{} = conn, module) do
    raise(AlreadySentError, """
    the response was already sent.

        Status code: #{conn.status}
        Request path: #{conn.request_path}
        Method: #{conn.method}
        View module: #{inspect(module)}
    """)
  end

  @doc """
  Retrieves the current view for the given format.

  If no format is given, takes the current one from the connection.
  """
  @spec view_module(Plug.Conn.t(), binary | nil) :: atom
  def view_module(conn, format \\ nil) do
    format = format || get_safe_format(conn)

    # TODO: Remove the first branch once code paths are deprecated and then removed
    case conn.private[:phoenix_view] do
      %{_: value} when value != nil ->
        value

      %{^format => value} ->
        value

      formats ->
        raise "no view was found for the format: #{inspect(format)}. " <>
                "The supported formats are: #{inspect(Map.keys(formats || %{}) -- [:_])}"
    end
  end

  @doc """
  Stores the layout for rendering.

  The layout must be given as keyword list where the key is the request
  format the layout will be applied to (such as `:html`) and the value
  is one of:

    * `{module, layout}` with the `module` the layout is defined and
      the name of the `layout` as an atom

    * `false` which disables the layout

  If `false` is given without a format, all layouts are disabled.

  ## Examples

      iex> layout(conn)
      false

      iex> conn = put_layout(conn, html: {AppView, :application})
      iex> layout(conn)
      {AppView, :application}

      iex> conn = put_layout(conn, html: {AppView, :print})
      iex> layout(conn)
      {AppView, :print}

  Raises `Plug.Conn.AlreadySentError` if `conn` is already sent.
  """
  @spec put_layout(Plug.Conn.t(), [{format :: atom, layout}] | false) :: Plug.Conn.t()
  def put_layout(%Plug.Conn{state: state} = conn, layout) do
    if state in @unsent do
      put_private_layout(conn, :phoenix_layout, :replace, layout)
    else
      raise AlreadySentError, """
      the response was already sent.

          Status code: #{conn.status}
          Request path: #{conn.request_path}
          Method: #{conn.method}
          Layout: #{inspect(layout)}
      """
    end
  end

  defp put_private_layout(conn, private_key, kind, layouts) when is_list(layouts) do
    formats =
      Map.new(layouts, fn
        {format, false} ->
          {Atom.to_string(format), false}

        {format, layout} when is_atom(layout) ->
          format = Atom.to_string(format)

          case conn.private[private_key] do
            %{^format => {mod, _}} ->
              IO.warn("""
              specifying a layout without module is deprecated, use #{format}: #{inspect({mod, layout})} instead\
              """)

              {format, {mod, layout}}

            %{} ->
              raise "cannot use put_layout/2 or put_root_layout/2 with atom because " <>
                      "there is no previous layout set for format #{inspect(format)}"
          end

        {format, {mod, layout}} when is_atom(mod) and is_atom(layout) ->
          {Atom.to_string(format), {mod, layout}}

        {format, other} ->
          raise ArgumentError, """
          put_layout and put_root_layout expects an module and template per format, such as:

              #{format}: {MyView, :app}

          Got:

              #{inspect(other)}
          """
      end)

    put_private_formats(conn, private_key, kind, formats)
  end

  defp put_private_layout(conn, private_key, kind, no_format) do
    case no_format do
      false ->
        put_private_formats(conn, private_key, kind, %{_: false})

      # TODO: Deprecate this branch on Phoenix v1.9
      {mod, layout} when is_atom(mod) ->
        put_private_formats(conn, private_key, kind, %{_: {mod, layout}})

      layout when is_binary(layout) or is_atom(layout) ->
        case Map.get(conn.private, private_key, %{_: false}) do
          %{_: {mod, _}} ->
            IO.warn("""
            specifying put_layout(conn, template) or put_new_layout(conn, template) is deprecated, \
            specify the layout with the format instead: put_layout(conn, html: #{inspect({mod, layout})})
            """)

            put_private_formats(conn, private_key, kind, %{_: {mod, layout}})

          %{_: false} ->
            raise "cannot use put_layout/2 or put_root_layout/2 with atom/binary when layout is false, use a tuple instead"

          %{} ->
            raise "you must pass the format when using put_layout/2 or put_root_layout/2 and a previous format was set, " <>
                    "such as: put_layout(conn, html: #{inspect(layout)})"
        end
    end
  end

  @doc """
  Stores the layout for rendering if one was not stored yet.

  See `put_layout/2` for more information.

  Raises `Plug.Conn.AlreadySentError` if `conn` is already sent.
  """
  # TODO: Remove | layout from the spec once we deprecate put_new_layout on controllers
  @spec put_new_layout(Plug.Conn.t(), [{format :: atom, layout}] | layout) :: Plug.Conn.t()
  def put_new_layout(%Plug.Conn{state: state} = conn, layout)
      when (is_tuple(layout) and tuple_size(layout) == 2) or is_list(layout) or layout == false do
    unless state in @unsent do
      raise(AlreadySentError, """
      the response was already sent.

          Status code: #{conn.status}
          Request path: #{conn.request_path}
          Method: #{conn.method}
          Layout: #{inspect(layout)}
      """)
    end

    put_private_layout(conn, :phoenix_layout, :new, layout)
  end

  @doc """
  Stores the root layout for rendering.

  The layout must be given as keyword list where the key is the request
  format the layout will be applied to (such as `:html`) and the value
  is one of:

    * `{module, layout}` with the `module` the layout is defined and
      the name of the `layout` as an atom

    * `layout` when the name of the layout. This requires a layout for
      the given format in the shape of `{module, layout}` to be previously
      given

    * `false` which disables the layout

  ## Examples

      iex> root_layout(conn)
      false

      iex> conn = put_root_layout(conn, html: {AppView, :root})
      iex> root_layout(conn)
      {AppView, :root}

      iex> conn = put_root_layout(conn, html: :bare)
      iex> root_layout(conn)
      {AppView, :bare}

  Raises `Plug.Conn.AlreadySentError` if `conn` is already sent.
  """
  @spec put_root_layout(Plug.Conn.t(), [{format :: atom, layout}] | false) ::
          Plug.Conn.t()
  def put_root_layout(%Plug.Conn{state: state} = conn, layout) do
    if state in @unsent do
      put_private_layout(conn, :phoenix_root_layout, :replace, layout)
    else
      raise AlreadySentError, """
      the response was already sent.

          Status code: #{conn.status}
          Request path: #{conn.request_path}
          Method: #{conn.method}
          Layout: #{inspect(layout)}
      """
    end
  end

  @doc false
  @deprecated "put_layout_formats/2 is deprecated, pass a keyword list to put_layout/put_root_layout instead"
  @spec put_layout_formats(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def put_layout_formats(%Plug.Conn{state: state} = conn, formats)
      when state in @unsent and is_list(formats) do
    put_private(conn, :phoenix_layout_formats, formats)
  end

  def put_layout_formats(%Plug.Conn{} = conn, _formats) do
    raise(AlreadySentError, """
    the response was already sent.

        Status code: #{conn.status}
        Request path: #{conn.request_path}
        Method: #{conn.method}
    """)
  end

  @doc false
  @deprecated "layout_formats/1 is deprecated, pass a keyword list to put_layout/put_root_layout instead"
  @spec layout_formats(Plug.Conn.t()) :: [String.t()]
  def layout_formats(conn) do
    Map.get(conn.private, :phoenix_layout_formats, ~w(html))
  end

  @doc """
  Retrieves the current layout for the given format.

  If no format is given, takes the current one from the connection.
  """
  @spec layout(Plug.Conn.t(), binary | nil) :: {atom, String.t() | atom} | false
  def layout(conn, format \\ nil) do
    get_private_layout(conn, :phoenix_layout, format)
  end

  @doc """
  Retrieves the current root layout for the given format.

  If no format is given, takes the current one from the connection.
  """
  @spec root_layout(Plug.Conn.t(), binary | nil) :: {atom, String.t() | atom} | false
  def root_layout(conn, format \\ nil) do
    get_private_layout(conn, :phoenix_root_layout, format)
  end

  defp get_private_layout(conn, priv_key, format) do
    format = format || get_safe_format(conn)

    # TODO: Remove _ handling once layouts(false) is set to remove all formats
    case conn.private[priv_key] do
      %{_: value} -> if format in [nil | layout_formats(conn)], do: value, else: false
      %{^format => value} -> value
      _ -> false
    end
  end

  @doc """
  Render the given template or the default template
  specified by the current action with the given assigns.

  See `render/3` for more information.
  """
  @spec render(Plug.Conn.t(), Keyword.t() | map | binary | atom) :: Plug.Conn.t()
  def render(conn, template_or_assigns \\ [])

  def render(conn, template) when is_binary(template) or is_atom(template) do
    render(conn, template, [])
  end

  def render(conn, assigns) do
    render(conn, action_name(conn), assigns)
  end

  @doc """
  Renders the given `template` and `assigns` based on the `conn` information.

  Once the template is rendered, the template format is set as the response
  content type (for example, an HTML template will set "text/html" as response
  content type) and the data is sent to the client with default status of 200.

  ## Arguments

    * `conn` - the `Plug.Conn` struct

    * `template` - which may be an atom or a string. If an atom, like `:index`,
      it will render a template with the same format as the one returned by
      `get_format/1`. For example, for an HTML request, it will render
      the "index.html" template. If the template is a string, it must contain
      the extension too, like "index.json"

    * `assigns` - a dictionary with the assigns to be used in the view. Those
      assigns are merged and have higher precedence than the connection assigns
      (`conn.assigns`)

  ## Examples

  To render a template, you must configure your controller with the formats
  to render. You can do so on `use`, which will infer the modules based on
  the controller name:

      defmodule MyAppWeb.UserController do
        # Will use MyAppWeb.UserHTML and MyAppWeb.UserJSON
        use Phoenix.Controller, formats: [:html, :json]
      end

  With the formats set, you can render in two ways, either passing a string
  with the template name and explicit format:

      def show(conn, _params) do
        render(conn, "show.html", message: "Hello")
      end

  The example above renders a template "show.html" from the `MyAppWeb.UserHTML`
  and sets the response content type to "text/html".

  Or, if you want the template format to be set dynamically based on the request,
  you can pass an atom instead (without the extension):

      def show(conn, _params) do
        render(conn, :show.html, message: "Hello")
      end

  If the formats are not known at compile-time, you can call `put_view/2`
  at runtime:

      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def show(conn, _params) do
          conn
          |> put_view(html: MyAppWeb.UserHTML)
          render(conn, "show.html", message: "Hello")
        end
      end

  """
  @spec render(Plug.Conn.t(), binary | atom, Keyword.t() | map) :: Plug.Conn.t()
  def render(conn, template, assigns)
      when is_atom(template) and (is_map(assigns) or is_list(assigns)) do
    format =
      get_format(conn) ||
        raise "cannot render template #{inspect(template)} because conn.params[\"_format\"] is not set. " <>
                "Please set `plug :accepts, ~w(html json ...)` in your pipeline."

    render_and_send(conn, format, Atom.to_string(template), assigns)
  end

  def render(conn, template, assigns)
      when is_binary(template) and (is_map(assigns) or is_list(assigns)) do
    {base, format} = split_template(template)
    conn |> put_format(format) |> render_and_send(format, base, assigns)
  end

  def render(conn, view, template)
      when is_atom(view) and (is_binary(template) or is_atom(template)) do
    IO.warn(
      "Phoenix.Controller.render/3 with a view is deprecated, see the documentation for render/3 for an alternative"
    )

    render(conn, view, template, [])
  end

  @doc false
  @deprecated "render/4 is deprecated. Use put_view + render/3"
  def render(conn, view, template, assigns)
      when is_atom(view) and (is_binary(template) or is_atom(template)) do
    conn
    |> put_view(view)
    |> render(template, assigns)
  end

  defp render_and_send(conn, format, template, assigns) do
    view = view_module(conn, format)
    conn = prepare_assigns(conn, assigns, template, format)
    data = render_with_layouts(conn, view, template, format)

    conn
    |> ensure_resp_content_type(MIME.type(format))
    |> send_resp(conn.status || 200, data)
  end

  defp render_with_layouts(conn, view, template, format) do
    render_assigns = Map.put(conn.assigns, :conn, conn)

    case root_layout(conn, format) do
      {layout_mod, layout_tpl} ->
        {layout_base, _} = split_template(layout_tpl)
        inner = template_render(view, template, format, render_assigns)
        root_assigns = render_assigns |> Map.put(:inner_content, inner) |> Map.delete(:layout)
        template_render_to_iodata(layout_mod, layout_base, format, root_assigns)

      false ->
        template_render_to_iodata(view, template, format, render_assigns)
    end
  end

  defp template_render(view, template, format, assigns) do
    metadata = %{view: view, template: template, format: format}

    :telemetry.span([:phoenix, :controller, :render], metadata, fn ->
      {Phoenix.Template.render(view, template, format, assigns), metadata}
    end)
  end

  defp template_render_to_iodata(view, template, format, assigns) do
    metadata = %{view: view, template: template, format: format}

    :telemetry.span([:phoenix, :controller, :render], metadata, fn ->
      {Phoenix.Template.render_to_iodata(view, template, format, assigns), metadata}
    end)
  end

  defp prepare_assigns(conn, assigns, template, format) do
    assigns = to_map(assigns)

    layout =
      case assigns_layout(conn, assigns, format) do
        {mod, layout} when is_binary(layout) -> {mod, Path.rootname(layout)}
        {mod, layout} when is_atom(layout) -> {mod, Atom.to_string(layout)}
        false -> false
      end

    conn
    |> put_private(:phoenix_template, template <> "." <> format)
    |> Map.update!(:assigns, fn prev ->
      prev
      |> Map.merge(assigns)
      |> Map.put(:layout, layout)
    end)
  end

  defp assigns_layout(_conn, %{layout: layout}, _format), do: layout

  defp assigns_layout(conn, _assigns, format) do
    # TODO: Remove _ handling once layouts(false) is set to remove all formats
    case conn.private[:phoenix_layout] do
      %{^format => bad_value, _: good_value} when good_value != false ->
        IO.warn("""
        conflicting layouts found. A layout has been set with format, such as:

            put_layout(conn, #{format}: #{inspect(bad_value)})

        But also without format:

            put_layout(conn, #{inspect(good_value)})

        In this case, the layout without format will always win.
        Passing the layout without a format is currently soft-deprecated.
        If you use layouts with formats, make sure that they are
        used everywhere. Also remember to configure your controller
        to use layouts with formats:

            use Phoenix.Controller, layouts: [#{format}: #{inspect(bad_value)}]
        """)

        if format in layout_formats(conn), do: good_value, else: false

      %{_: value} ->
        if format in layout_formats(conn), do: value, else: false

      %{^format => value} ->
        value

      _ ->
        false
    end
  end

  defp to_map(assigns) when is_map(assigns), do: assigns
  defp to_map(assigns) when is_list(assigns), do: :maps.from_list(assigns)

  defp split_template(name) when is_atom(name), do: {Atom.to_string(name), nil}

  defp split_template(name) when is_binary(name) do
    case :binary.split(name, ".") do
      [base, format] ->
        {base, format}

      [^name] ->
        raise "cannot render template #{inspect(name)} without format. Use an atom if the " <>
                "template format is meant to be set dynamically based on the request format"

      [base | formats] ->
        {base, List.last(formats)}
    end
  end

  defp send_resp(conn, default_status, default_content_type, body) do
    conn
    |> ensure_resp_content_type(default_content_type)
    |> send_resp(conn.status || default_status, body)
  end

  defp ensure_resp_content_type(%Plug.Conn{resp_headers: resp_headers} = conn, content_type) do
    if List.keyfind(resp_headers, "content-type", 0) do
      conn
    else
      content_type = content_type <> "; charset=utf-8"
      %{conn | resp_headers: [{"content-type", content_type} | resp_headers]}
    end
  end

  @doc """
  Puts the url string or `%URI{}` to be used for route generation.

  This function overrides the default URL generation pulled
  from the `%Plug.Conn{}`'s endpoint configuration.

  ## Examples

  Imagine your application is configured to run on "example.com"
  but after the user signs in, you want all links to use
  "some_user.example.com". You can do so by setting the proper
  router url configuration:

      def put_router_url_by_user(conn) do
        put_router_url(conn, get_user_from_conn(conn).account_name <> ".example.com")
      end

  Now when you call `Routes.some_route_url(conn, ...)`, it will use
  the router url set above. Keep in mind that, if you want to generate
  routes to the *current* domain, it is preferred to use
  `Routes.some_route_path` helpers, as those are always relative.
  """
  def put_router_url(conn, %URI{} = uri) do
    put_private(conn, :phoenix_router_url, URI.to_string(uri))
  end

  def put_router_url(conn, url) when is_binary(url) do
    put_private(conn, :phoenix_router_url, url)
  end

  @doc """
  Puts the URL or `%URI{}` to be used for the static url generation.

  Using this function on a `%Plug.Conn{}` struct tells `static_url/2` to use
  the given information for URL generation instead of the `%Plug.Conn{}`'s
  endpoint configuration (much like `put_router_url/2` but for static URLs).
  """
  def put_static_url(conn, %URI{} = uri) do
    put_private(conn, :phoenix_static_url, URI.to_string(uri))
  end

  def put_static_url(conn, url) when is_binary(url) do
    put_private(conn, :phoenix_static_url, url)
  end

  @doc """
  Puts the format in the connection.

  This format is used when rendering a template as an atom.
  For example, `render(conn, :foo)` will render `"foo.FORMAT"`
  where the format is the one set here. The default format
  is typically set from the negotiation done in `accepts/2`.

  See `get_format/1` for retrieval.
  """
  def put_format(conn, format), do: put_private(conn, :phoenix_format, to_string(format))

  @doc """
  Returns the request format, such as "json", "html".

  This format is used when rendering a template as an atom.
  For example, `render(conn, :foo)` will render `"foo.FORMAT"`
  where the format is the one set here. The default format
  is typically set from the negotiation done in `accepts/2`.
  """
  def get_format(conn) do
    conn.private[:phoenix_format] || conn.params["_format"]
  end

  defp get_safe_format(conn) do
    conn.private[:phoenix_format] ||
      case conn.params do
        %{"_format" => format} -> format
        %{} -> nil
      end
  end

  @doc """
  Sends the given file or binary as a download.

  The second argument must be `{:binary, contents}`, where
  `contents` will be sent as download, or`{:file, path}`,
  where `path` is the filesystem location of the file to
  be sent. Be careful to not interpolate the path from
  external parameters, as it could allow traversal of the
  filesystem.

  The download is achieved by setting "content-disposition"
  to attachment. The "content-type" will also be set based
  on the extension of the given filename but can be customized
  via the `:content_type` and `:charset` options.

  ## Options

    * `:filename` - the filename to be presented to the user
      as download
    * `:content_type` - the content type of the file or binary
      sent as download. It is automatically inferred from the
      filename extension
    * `:disposition` - specifies disposition type
      (`:attachment` or `:inline`). If `:attachment` was used,
      user will be prompted to save the file. If `:inline` was used,
      the browser will attempt to open the file.
      Defaults to `:attachment`.
    * `:charset` - the charset of the file, such as "utf-8".
      Defaults to none
    * `:offset` - the bytes to offset when reading. Defaults to `0`
    * `:length` - the total bytes to read. Defaults to `:all`
    * `:encode` - encodes the filename using `URI.encode/2`.
      Defaults to `true`. When `false`, disables encoding. If you
      disable encoding, you need to guarantee there are no special
      characters in the filename, such as quotes, newlines, etc.
      Otherwise you can expose your application to security attacks

  ## Examples

  To send a file that is stored inside your application priv
  directory:

      path = Application.app_dir(:my_app, "priv/prospectus.pdf")
      send_download(conn, {:file, path})

  When using `{:file, path}`, the filename is inferred from the
  given path but may also be set explicitly.

  To allow the user to download contents that are in memory as
  a binary or string:

      send_download(conn, {:binary, "world"}, filename: "hello.txt")

  See `Plug.Conn.send_file/3` and `Plug.Conn.send_resp/3` if you
  would like to access the low-level functions used to send files
  and responses via Plug.
  """
  def send_download(conn, kind, opts \\ [])

  def send_download(conn, {:file, path}, opts) do
    filename = opts[:filename] || Path.basename(path)
    offset = opts[:offset] || 0
    length = opts[:length] || :all

    conn
    |> prepare_send_download(filename, opts)
    |> send_file(conn.status || 200, path, offset, length)
  end

  def send_download(conn, {:binary, contents}, opts) do
    filename =
      opts[:filename] || raise ":filename option is required when sending binary download"

    conn
    |> prepare_send_download(filename, opts)
    |> send_resp(conn.status || 200, contents)
  end

  defp prepare_send_download(conn, filename, opts) do
    content_type = opts[:content_type] || MIME.from_path(filename)
    encoded_filename = encode_filename(filename, Keyword.get(opts, :encode, true))
    disposition_type = get_disposition_type(Keyword.get(opts, :disposition, :attachment))
    warn_if_ajax(conn)

    disposition = ~s[#{disposition_type}; filename="#{encoded_filename}"]

    disposition =
      if encoded_filename != filename do
        disposition <> "; filename*=utf-8''#{encoded_filename}"
      else
        disposition
      end

    conn
    |> put_resp_content_type(content_type, opts[:charset])
    |> put_resp_header("content-disposition", disposition)
  end

  defp encode_filename(filename, false), do: filename
  defp encode_filename(filename, true), do: URI.encode(filename, &URI.char_unreserved?/1)

  defp get_disposition_type(:attachment), do: "attachment"
  defp get_disposition_type(:inline), do: "inline"

  defp get_disposition_type(other),
    do:
      raise(
        ArgumentError,
        "expected :disposition to be :attachment or :inline, got: #{inspect(other)}"
      )

  defp ajax?(conn) do
    case get_req_header(conn, "x-requested-with") do
      [value] -> value in ["XMLHttpRequest", "xmlhttprequest"]
      [] -> false
    end
  end

  defp warn_if_ajax(conn) do
    if ajax?(conn) do
      Logger.warning(
        "send_download/3 has been invoked during an AJAX request. " <>
          "The download may not work as expected under XMLHttpRequest"
      )
    end
  end

  @doc """
  Scrubs the parameters from the request.

  This process is two-fold:

    * Checks to see if the `required_key` is present
    * Changes empty parameters of `required_key` (recursively) to nils

  This function is useful for removing empty strings sent
  via HTML forms. If you are providing an API, there
  is likely no need to invoke `scrub_params/2`.

  If the `required_key` is not present, it will
  raise `Phoenix.MissingParamError`.

  ## Examples

      iex> scrub_params(conn, "user")

  """
  @spec scrub_params(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def scrub_params(%Plug.Conn{} = conn, required_key) when is_binary(required_key) do
    param = Map.get(conn.params, required_key) |> scrub_param()

    unless param do
      raise Phoenix.MissingParamError, key: required_key
    end

    params = Map.put(conn.params, required_key, param)
    %{conn | params: params}
  end

  defp scrub_param(%{__struct__: mod} = struct) when is_atom(mod) do
    struct
  end

  defp scrub_param(%{} = param) do
    Enum.reduce(param, %{}, fn {k, v}, acc ->
      Map.put(acc, k, scrub_param(v))
    end)
  end

  defp scrub_param(param) when is_list(param) do
    Enum.map(param, &scrub_param/1)
  end

  defp scrub_param(param) do
    if scrub?(param), do: nil, else: param
  end

  defp scrub?(" " <> rest), do: scrub?(rest)
  defp scrub?(""), do: true
  defp scrub?(_), do: false

  @doc """
  Enables CSRF protection.

  Currently used as a wrapper function for `Plug.CSRFProtection`
  and mainly serves as a function plug in `YourApp.Router`.

  Check `get_csrf_token/0` and `delete_csrf_token/0` for
  retrieving and deleting CSRF tokens.
  """
  def protect_from_forgery(conn, opts \\ []) do
    Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(opts))
  end

  @doc """
  Put headers that improve browser security.

  It sets the following headers, if they are not already set:

    * `content-security-policy` - It sets `frame-ancestors` and
      `base-uri` to `self`, restricting embedding and the use of
      `<base>` element to same origin respectively. It is equivalent
      to setting `"base-uri 'self'; frame-ancestors 'self';"`

    * `referrer-policy` - only send origin on cross origin requests

    * `x-content-type-options` - set to nosniff. This requires
      script and style tags to be sent with proper content type

    * `x-permitted-cross-domain-policies` - set to none to restrict
      Adobe Flash Player’s access to data

  A custom headers map may also be given to be merged with defaults.

  It is recommended for custom header keys to be in lowercase, to avoid sending
  duplicate keys or invalid responses.
  """
  def put_secure_browser_headers(conn, headers \\ %{})

  def put_secure_browser_headers(conn, []) do
    put_secure_defaults(conn)
  end

  def put_secure_browser_headers(conn, headers) when is_map(headers) do
    conn
    |> put_secure_defaults()
    |> merge_resp_headers(headers)
  end

  defp put_secure_defaults(%Plug.Conn{resp_headers: resp_headers} = conn) do
    headers = [
      {"referrer-policy", "strict-origin-when-cross-origin"},
      {"content-security-policy", "base-uri 'self'; frame-ancestors 'self';"},
      {"x-content-type-options", "nosniff"},
      {"x-permitted-cross-domain-policies", "none"}
    ]

    resp_headers =
      Enum.reduce(headers, resp_headers, fn {key, _} = pair, acc ->
        case :lists.keymember(key, 1, acc) do
          true -> acc
          false -> [pair | acc]
        end
      end)

    %{conn | resp_headers: resp_headers}
  end

  @doc """
  Gets or generates a CSRF token.

  If a token exists, it is returned, otherwise it is generated and stored
  in the process dictionary.
  """
  defdelegate get_csrf_token(), to: Plug.CSRFProtection

  @doc """
  Deletes the CSRF token from the process dictionary.

  *Note*: The token is deleted only after a response has been sent.
  """
  defdelegate delete_csrf_token(), to: Plug.CSRFProtection

  @doc """
  Performs content negotiation based on the available formats.

  It receives a connection, a list of formats that the server
  is capable of rendering and then proceeds to perform content
  negotiation based on the request information. If the client
  accepts any of the given formats, the request proceeds.

  If the request contains a "_format" parameter, it is
  considered to be the format desired by the client. If no
  "_format" parameter is available, this function will parse
  the "accept" header and find a matching format accordingly.

  This function is useful when you may want to serve different
  content-types (such as JSON and HTML) from the same routes.
  However, if you always have distinct routes, you can also
  disable content negotiation and simply hardcode your format
  of choice in your route pipelines:

      plug :put_format, "html"

  It is important to notice that browsers have historically
  sent bad accept headers. For this reason, this function will
  default to "html" format whenever:

    * the accepted list of arguments contains the "html" format

    * the accept header specified more than one media type preceded
      or followed by the wildcard media type "`*/*`"

  This function raises `Phoenix.NotAcceptableError`, which is rendered
  with status 406, whenever the server cannot serve a response in any
  of the formats expected by the client.

  ## Examples

  `accepts/2` can be invoked as a function:

      iex> accepts(conn, ["html", "json"])

  or used as a plug:

      plug :accepts, ["html", "json"]
      plug :accepts, ~w(html json)

  ## Custom media types

  It is possible to add custom media types to your Phoenix application.
  The first step is to teach Plug about those new media types in
  your `config/config.exs` file:

      config :mime, :types, %{
        "application/vnd.api+json" => ["json-api"]
      }

  The key is the media type, the value is a list of formats the
  media type can be identified with. For example, by using
  "json-api", you will be able to use templates with extension
  "index.json-api" or to force a particular format in a given
  URL by sending "?_format=json-api".

  After this change, you must recompile plug:

      $ mix deps.clean mime --build
      $ mix deps.get

  And now you can use it in accepts too:

      plug :accepts, ["html", "json-api"]

  """
  @spec accepts(Plug.Conn.t(), [binary]) :: Plug.Conn.t()
  def accepts(conn, [_ | _] = accepted) do
    case conn.params do
      %{"_format" => format} ->
        handle_params_accept(conn, format, accepted)

      %{} ->
        handle_header_accept(conn, get_req_header(conn, "accept"), accepted)
    end
  end

  defp handle_params_accept(conn, format, accepted) do
    if format in accepted do
      put_format(conn, format)
    else
      raise Phoenix.NotAcceptableError,
        message: "unknown format #{inspect(format)}, expected one of #{inspect(accepted)}",
        accepts: accepted
    end
  end

  # In case there is no accept header or the header is */*
  # we use the first format specified in the accepts list.
  defp handle_header_accept(conn, header, [first | _]) when header == [] or header == ["*/*"] do
    put_format(conn, first)
  end

  # In case there is a header, we need to parse it.
  # But before we check for */* because if one exists and we serve html,
  # we unfortunately need to assume it is a browser sending us a request.
  defp handle_header_accept(conn, [header | _], accepted) do
    if header =~ "*/*" and "html" in accepted do
      put_format(conn, "html")
    else
      parse_header_accept(conn, String.split(header, ","), [], accepted)
    end
  end

  defp parse_header_accept(conn, [h | t], acc, accepted) do
    case Plug.Conn.Utils.media_type(h) do
      {:ok, type, subtype, args} ->
        exts = parse_exts(type, subtype)
        q = parse_q(args)

        if format = q === 1.0 && find_format(exts, accepted) do
          put_format(conn, format)
        else
          parse_header_accept(conn, t, [{-q, h, exts} | acc], accepted)
        end

      :error ->
        parse_header_accept(conn, t, acc, accepted)
    end
  end

  defp parse_header_accept(conn, [], acc, accepted) do
    acc
    |> Enum.sort()
    |> Enum.find_value(&parse_header_accept(conn, &1, accepted))
    |> Kernel.||(refuse(conn, acc, accepted))
  end

  defp parse_header_accept(conn, {_, _, exts}, accepted) do
    if format = find_format(exts, accepted) do
      put_format(conn, format)
    end
  end

  defp parse_q(args) do
    case Map.fetch(args, "q") do
      {:ok, float} ->
        case Float.parse(float) do
          {float, _} -> float
          :error -> 1.0
        end

      :error ->
        1.0
    end
  end

  defp parse_exts("*", "*"), do: "*/*"
  defp parse_exts(type, "*"), do: type
  defp parse_exts(type, subtype), do: MIME.extensions(type <> "/" <> subtype)

  defp find_format("*/*", accepted), do: Enum.fetch!(accepted, 0)
  defp find_format(exts, accepted) when is_list(exts), do: Enum.find(exts, &(&1 in accepted))
  defp find_format(_type_range, []), do: nil

  defp find_format(type_range, [h | t]) do
    mime_type = MIME.type(h)

    case Plug.Conn.Utils.media_type(mime_type) do
      {:ok, accepted_type, _subtype, _args} when type_range === accepted_type -> h
      _ -> find_format(type_range, t)
    end
  end

  @spec refuse(term(), [tuple], [binary]) :: no_return()
  defp refuse(_conn, given, accepted) do
    raise Phoenix.NotAcceptableError,
      accepts: accepted,
      message: """
      no supported media type in accept header.

      Expected one of #{inspect(accepted)} but got the following formats:

        * #{Enum.map_join(given, "\n  ", fn {_, header, exts} -> inspect(header) <> " with extensions: " <> inspect(exts) end)}

      To accept custom formats, register them under the :mime library
      in your config/config.exs file:

          config :mime, :types, %{
            "application/xml" => ["xml"]
          }

      And then run `mix deps.clean --build mime` to force it to be recompiled.
      """
  end

  @doc """
  Fetches the flash storage.
  """
  def fetch_flash(conn, _opts \\ []) do
    if Map.get(conn.assigns, :flash) do
      conn
    else
      session_flash = get_session(conn, "phoenix_flash")
      conn = persist_flash(conn, session_flash || %{})

      register_before_send(conn, fn conn ->
        flash = conn.assigns.flash
        flash_size = map_size(flash)

        cond do
          is_nil(session_flash) and flash_size == 0 ->
            conn

          flash_size > 0 and conn.status in 300..308 ->
            put_session(conn, "phoenix_flash", flash)

          true ->
            delete_session(conn, "phoenix_flash")
        end
      end)
    end
  end

  @doc """
  Merges a map into the flash.

  Returns the updated connection.

  ## Examples

      iex> conn = merge_flash(conn, info: "Welcome Back!")
      iex> Phoenix.Flash.get(conn.assigns.flash, :info)
      "Welcome Back!"

  """
  def merge_flash(conn, enumerable) do
    map = for {k, v} <- enumerable, into: %{}, do: {flash_key(k), v}
    persist_flash(conn, Map.merge(Map.get(conn.assigns, :flash, %{}), map))
  end

  @doc """
  Persists a value in flash.

  `key` can be any atom or binary value. Phoenix does not enforce which keys
  are stored in the flash, as long as the values are internally consistent.
  By default, the Phoenix generators use `:info` and `:error` keys.

  Returns the updated connection.

  ## Examples

      iex> conn = put_flash(conn, :info, "Welcome Back!")
      iex> Phoenix.Flash.get(conn.assigns.flash, :info)
      "Welcome Back!"

  """
  def put_flash(conn, key, message) do
    flash =
      Map.get(conn.assigns, :flash) ||
        raise ArgumentError, message: "flash not fetched, call fetch_flash/2"

    persist_flash(conn, Map.put(flash, flash_key(key), message))
  end

  @doc """
  Returns a map of previously set flash messages or an empty map.

  ## Examples

      iex> get_flash(conn)
      %{}

      iex> conn = put_flash(conn, :info, "Welcome Back!")
      iex> get_flash(conn)
      %{"info" => "Welcome Back!"}

  """
  @deprecated "get_flash/1 is deprecated. Use the @flash assign provided by the :fetch_flash plug"
  def get_flash(conn) do
    Map.get(conn.assigns, :flash) ||
      raise ArgumentError, message: "flash not fetched, call fetch_flash/2"
  end

  @doc """
  Returns a message from flash by `key` (or `nil` if no message is available for `key`).

  ## Examples

      iex> conn = put_flash(conn, :info, "Welcome Back!")
      iex> get_flash(conn, :info)
      "Welcome Back!"

  """
  @deprecated "get_flash/2 is deprecated. Use Phoenix.Flash.get(@flash, key) instead"
  def get_flash(conn, key) do
    get_flash(conn)[flash_key(key)]
  end

  @doc """
  Generates a status message from the template name.

  ## Examples

      iex> status_message_from_template("404.html")
      "Not Found"
      iex> status_message_from_template("whatever.html")
      "Internal Server Error"

  """
  def status_message_from_template(template) do
    template
    |> String.split(".")
    |> hd()
    |> String.to_integer()
    |> Plug.Conn.Status.reason_phrase()
  rescue
    _ -> "Internal Server Error"
  end

  @doc """
  Clears all flash messages.
  """
  def clear_flash(conn) do
    persist_flash(conn, %{})
  end

  defp flash_key(binary) when is_binary(binary), do: binary
  defp flash_key(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp persist_flash(conn, value) do
    assign(conn, :flash, value)
  end

  @doc """
  Returns the current request path with its default query parameters:

      iex> current_path(conn)
      "/users/123?existing=param"

  See `current_path/2` to override the default parameters.

  The path is normalized based on the `conn.script_name` and
  `conn.path_info`. For example, "/foo//bar/" will become "/foo/bar".
  If you want the original path, use `conn.request_path` instead.
  """
  def current_path(%Plug.Conn{query_string: ""} = conn) do
    normalized_request_path(conn)
  end

  def current_path(%Plug.Conn{query_string: query_string} = conn) do
    normalized_request_path(conn) <> "?" <> query_string
  end

  @doc """
  Returns the current path with the given query parameters.

  You may also retrieve only the request path by passing an
  empty map of params.

  ## Examples

      iex> current_path(conn)
      "/users/123?existing=param"

      iex> current_path(conn, %{new: "param"})
      "/users/123?new=param"

      iex> current_path(conn, %{filter: %{status: ["draft", "published"]}})
      "/users/123?filter[status][]=draft&filter[status][]=published"

      iex> current_path(conn, %{})
      "/users/123"

  The path is normalized based on the `conn.script_name` and
  `conn.path_info`. For example, "/foo//bar/" will become "/foo/bar".
  If you want the original path, use `conn.request_path` instead.
  """
  def current_path(%Plug.Conn{} = conn, params) when params == %{} do
    normalized_request_path(conn)
  end

  def current_path(%Plug.Conn{} = conn, params) do
    normalized_request_path(conn) <> "?" <> Plug.Conn.Query.encode(params)
  end

  defp normalized_request_path(%{path_info: info, script_name: script}) do
    "/" <> Enum.join(script ++ info, "/")
  end

  @doc """
  Returns the current request url with its default query parameters:

      iex> current_url(conn)
      "https://www.example.com/users/123?existing=param"

  See `current_url/2` to override the default parameters.
  """
  def current_url(%Plug.Conn{} = conn) do
    Phoenix.VerifiedRoutes.unverified_url(conn, current_path(conn))
  end

  @doc ~S"""
  Returns the current request URL with query params.

  The path will be retrieved from the currently requested path via
  `current_path/1`. The scheme, host and others will be received from
  the URL configuration in your Phoenix endpoint. The reason we don't
  use the host and scheme information in the request is because most
  applications are behind proxies and the host and scheme may not
  actually reflect the host and scheme accessed by the client. If you
  want to access the url precisely as requested by the client, see
  `Plug.Conn.request_url/1`.

  ## Examples

      iex> current_url(conn)
      "https://www.example.com/users/123?existing=param"

      iex> current_url(conn, %{new: "param"})
      "https://www.example.com/users/123?new=param"

      iex> current_url(conn, %{})
      "https://www.example.com/users/123"

  ## Custom URL Generation

  In some cases, you'll need to generate a request's URL, but using a
  different scheme, different host, etc. This can be accomplished in
  two ways.

  If you want to do so in a case-by-case basis, you can define a custom
  function that gets the endpoint URI configuration and changes it accordingly.
  For example, to get the current URL always in HTTPS format:

      def current_secure_url(conn, params \\ %{}) do
        current_uri = MyAppWeb.Endpoint.struct_url()
        current_path = Phoenix.Controller.current_path(conn, params)
        Phoenix.VerifiedRoutes.unverified_url(%URI{current_uri | scheme: "https"}, current_path)
      end

  However, if you want all generated URLs to always have a certain schema,
  host, etc, you may use `put_router_url/2`.
  """
  def current_url(%Plug.Conn{} = conn, %{} = params) do
    Phoenix.VerifiedRoutes.unverified_url(conn, current_path(conn, params))
  end

  @doc false
  def __plugs__(controller_module, opts) do
    if Keyword.get(opts, :put_default_views, true) do
      base = Phoenix.Naming.unsuffix(controller_module, "Controller")

      view =
        case Keyword.fetch(opts, :formats) do
          {:ok, formats} when is_list(formats) ->
            Enum.map(formats, fn
              format when is_atom(format) ->
                {format, :"#{base}#{String.upcase(to_string(format))}"}

              {format, suffix} ->
                {format, :"#{base}#{suffix}"}
            end)

          :error ->
            IO.warn(
              """
              use #{inspect(controller_module)} must receive the :formats option with \
              the formats you intend to render. To keep compatibility within your app, \
              you can list it as:

                  formats: [html: "View", json: "View", ...]

              Listing all formats your application renders.
              """,
              []
            )

            :"#{base}View"
        end

      layouts =
        case Keyword.fetch(opts, :layouts) do
          {:ok, formats} when is_list(formats) ->
            # TODO: Deprecate passing :layouts altogether in Phoenix v1.9,
            # use Phoenix.Controller should only set views
            Enum.map(formats, fn
              {format, mod} when is_atom(mod) ->
                {format, {mod, :app}}

              {format, {mod, template}} when is_atom(mod) and is_atom(template) ->
                {format, {mod, template}}

              other ->
                raise ArgumentError, """
                expected :layouts to be a list of format module pairs of the form: [html: DemoWeb.Layouts] or [html: {DemoWeb.Layouts, :app}]

                Got: #{inspect(other)}
                """
            end)

          :error ->
            cond do
              namespace = Keyword.get(opts, :namespace) ->
                layout = Module.concat(namespace, "LayoutView")

                IO.warn(
                  """
                  the :namespace option given to #{inspect(controller_module)} is deprecated.
                  Set "plug :put_layout, html: #{inspect(layout)}" instead\
                  """,
                  []
                )

                {layout, :app}

              Keyword.has_key?(opts, :formats) ->
                []

              true ->
                layout =
                  controller_module
                  |> Atom.to_string()
                  |> String.split(".")
                  |> Enum.drop(-1)
                  |> Enum.take(2)
                  |> Kernel.++(["LayoutView"])
                  |> Module.concat()

                {layout, :app}
            end
        end

      {layouts, view}
    else
      IO.warn(
        """
        the :put_default_views option given to #{inspect(controller_module)} is deprecated.
        Set formats: [] instead\
        """,
        []
      )

      false
    end
  end
end
