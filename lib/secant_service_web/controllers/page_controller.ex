defmodule SecantServiceWeb.PageController do
  use SecantServiceWeb, :controller

  alias SecantService.SecNodes

  def home(conn, _params) do
    # The template renders the app layout itself.
    render(conn, :home, layout: false, counts: SecNodes.overview_counts())
  end
end
