defmodule GlificWeb.Providers.Swiftchat.Router do
  @moduledoc """
  A SwiftChat router which redirects the incoming webhook requests to
  their controller actions, mirroring `Providers.Maytapi.Router`.
  """

  use GlificWeb, :router

  alias GlificWeb.Providers.Swiftchat.Controllers

  scope "/swiftchat", Controllers do
    scope "/message" do
      post("/text", MessageController, :text)
      post("/interactive", MessageController, :interactive)
    end

    scope "/unknown" do
      post("/*unknown", DefaultController, :unknown)
    end

    post("/*unknown", DefaultController, :unknown)
    get("/*unknown", DefaultController, :unknown)
  end
end
