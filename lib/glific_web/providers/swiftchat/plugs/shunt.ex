defmodule GlificWeb.Providers.Swiftchat.Plugs.Shunt do
  @moduledoc """
  A SwiftChat shunt which redirects all incoming webhook requests to the
  SwiftChat router based on the payload's `type` field.

  Org attribution is via the existing `SubdomainPlug` (ADR-003): by the
  time this plug runs, `conn.assigns[:organization_id]` is already set
  from the request host — no new plug, no org token in the path.

  Confirmed inbound envelope (`docs/prds/PRD-001-spike-notes.md` §3):
  `{"from", "type", "timestamp", "message_id", "conversation_id",
  "conversation_initiated_by", <type-specific key>}`. Docs warn new
  `type` values may appear over time, so the catch-all clause routes
  anything undocumented to a 200-returning default handler instead of
  dropping the connection — SwiftChat's retry behavior on non-200s is
  unknown (residual T-01 question), so we never risk a retry storm on an
  unrecognized payload.
  """

  alias Plug.Conn

  alias Glific.{Appsignal, Partners, Partners.Organization, Repo}
  alias GlificWeb.Providers.Swiftchat.Router

  @doc false
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @doc """
  Build the context with the root user for all SwiftChat calls, this
  gives us permission to update contacts etc
  """
  @spec build_context(Conn.t()) :: Organization.t()
  def build_context(conn) do
    organization = Partners.organization(conn.assigns[:organization_id])
    Repo.put_current_user(organization.root_user)
    organization
  end

  @text_types ~w(text)
  @interactive_types ~w(button_response multi_select_button_response persistent_menu_response)

  @doc false
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(%Conn{params: %{"type" => type}} = conn, opts) when type in @text_types do
    organization = build_context(conn)

    path =
      ["swiftchat"] ++
        if Glific.safe_string_to_atom(organization.status) == :active,
          do: ["message", "text"],
          else: ["not_active"]

    conn
    |> change_path_info(path)
    |> Router.call(opts)
  end

  @doc false
  def call(%Conn{params: %{"type" => type}} = conn, opts) when type in @interactive_types do
    organization = build_context(conn)

    path =
      ["swiftchat"] ++
        if Glific.safe_string_to_atom(organization.status) == :active,
          do: ["message", "interactive"],
          else: ["not_active"]

    conn
    |> change_path_info(path)
    |> Router.call(opts)
  end

  @doc false
  # Everything else — media types (T-08's job), message_rated, date,
  # media_list, and any future/unknown `type` — is routed to the
  # catch-all default handler, which always returns 200. We must not
  # drop a non-200 for these: SwiftChat's retry behavior on failures is
  # undocumented (residual T-01 question, Q3-adjacent).
  def call(%Conn{params: %{"type" => _type}} = conn, opts) do
    organization = build_context(conn)

    path =
      ["swiftchat"] ++
        if Glific.safe_string_to_atom(organization.status) == :active,
          do: ["unknown", "unknown"],
          else: ["not_active"]

    conn
    |> change_path_info(path)
    |> Router.call(opts)
  end

  @doc false
  def call(conn, opts) do
    conn
    |> change_path_info(["swiftchat", "unknown", "unknown"])
    |> Router.call(opts)
  end

  @doc false
  @spec change_path_info(Plug.Conn.t(), list()) :: Plug.Conn.t()
  def change_path_info(conn, new_path) do
    Appsignal.set_namespace("swiftchat_webhooks")
    put_in(conn.path_info, new_path)
  end
end
