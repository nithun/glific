defmodule GlificWeb.Providers.Swiftchat.Controllers.DefaultController do
  @moduledoc """
  Catch-all controller for SwiftChat webhook payload types not yet
  handled by a dedicated controller (media types = T-08, `message_rated`,
  `date`, `media_list`, and any future/unknown `type`). Always returns
  200 — SwiftChat's retry behavior on non-200s is undocumented, so a
  dropped/failing response here risks a retry storm rather than a
  silently-lost event.
  """

  use GlificWeb, :controller
  require Logger

  @doc false
  @spec handler(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  def handler(conn, _params, _msg) do
    conn
    |> Plug.Conn.send_resp(200, "")
    |> Plug.Conn.halt()
  end

  @doc """
  Logs and acks any SwiftChat payload type we don't yet handle.
  """
  @spec unknown(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unknown(conn, params) do
    Logger.info(
      "SwiftChat: received unhandled webhook type '#{params["type"]}' for org #{conn.assigns[:organization_id]}"
    )

    handler(conn, params, "unknown handler")
  end
end
