defmodule SecantServiceWeb.Router do
  use SecantServiceWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SecantServiceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]

    plug AshAuthentication.Strategy.ApiKey.Plug,
      resource: SecantService.Accounts.User,
      # if you want to require an api key to be supplied, set `required?` to true
      required?: false

    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", SecantServiceWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {SecantServiceWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {SecantServiceWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {SecantServiceWeb.LiveUserAuth, :live_no_user}

      live "/dashboard", DashboardLive.Index
      live "/browse", DataBrowserLive.Index, :index
      live "/browse/node/:uuid", NodeBrowserLive.Index, :index
    end
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", SecantServiceWeb.AshJsonApiRouter
  end

  scope "/", SecantServiceWeb do
    pipe_through :browser

    get "/", PageController, :home

    sign_in_route auth_routes_prefix: "/auth",
                  overrides: [SecantServiceWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    sign_out_route AuthController, "/sign-out",
      overrides: [SecantServiceWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    auth_routes AuthController, SecantService.Accounts.User, path: "/auth"

    reset_route auth_routes_prefix: "/auth",
                overrides: [SecantServiceWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    confirm_route SecantService.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [SecantServiceWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]
  end

  # Other scopes may use custom stacks.
  # scope "/api", SecantServiceWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:secant_service, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: MyAppWeb.Telemetry,
        additional_pages: [
          flame_on: FlameOn.DashboardPage
        ]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  if Application.compile_env(:secant_service, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
