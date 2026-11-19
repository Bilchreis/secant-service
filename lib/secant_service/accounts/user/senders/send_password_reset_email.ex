defmodule SecantService.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use SecantServiceWeb, :verified_routes

  import Swoosh.Email

  alias SecantService.Mailer

  @impl true
  def send(user, token, _) do
    new()
    # TODO: Replace with your email
    |> from({"noreply", "noreply@example.com"})
    |> to(to_string(user.email))
    |> subject("Reset your password")
    |> html_body(body(token: token))
    |> Mailer.deliver!()
  end

  defp body(params) do
    # The AshAuthentication password-reset page isn't mounted in the router yet,
    # so this can't be a verified ~p route.
    url = SecantServiceWeb.Endpoint.url() <> "/password-reset/#{params[:token]}"

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end
end
