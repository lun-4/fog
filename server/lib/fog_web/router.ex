defmodule FogWeb.Router do
  use FogWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FogWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    # TODO why doesnt this work with accept: text/event-stream
    # plug(:accepts, ["json", "text/event-stream"])
    plug(FogWeb.AuthPlug)
  end

  scope "/api/v1", FogWeb do
    pipe_through(:api)

    get("/cli/query", CLIController, :query)
  end

  scope "/", FogWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:fog, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: FogWeb.Telemetry)
    end
  end
end
