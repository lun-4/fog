defmodule FogWeb.Router do
  use FogWeb, :router

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:urlencoded, :json],
      pass: ["text/*"],
      body_reader: {CacheBodyReader, :read_body, []},
      json_decoder: Jason

    plug(:accepts, ["json"])
  end

  scope "/api/v1", FogWeb do
    pipe_through(:api)
    post("/logline", LogController, :incoming_line)
    get("/logs", LogController, :fetch_logs)
  end

  defmodule CacheBodyReader do
    def read_body(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
      conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
      {:ok, body, conn}
    end
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
      pipe_through([:fetch_session, :protect_from_forgery])

      live_dashboard("/dashboard", metrics: FogWeb.Telemetry)
    end
  end
end
