defmodule SecantServiceWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  # Restyles the Ash Authentication Phoenix white-label pages (sign-in,
  # register, password reset, confirm, sign-out) to use daisyUI classes
  # consistent with the rest of the app (see Layouts.app, core_components.ex).
  #
  # For a complete reference, see https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html

  alias AshAuthentication.Phoenix.{
    Components,
    ConfirmLive,
    ResetLive,
    SignInLive,
    SignOutLive
  }

  @page_root_class "grid min-h-screen place-items-center bg-base-200 px-4 py-12"
  @card_class "card card-border bg-base-100 shadow-sm w-full max-w-sm"
  @heading_class "card-title text-2xl"
  @toggler_class "link link-primary text-sm"
  @submit_class "btn btn-primary w-full mt-4"
  @logo_bg_class "bg-[url('/images/secant-service.svg')] bg-no-repeat bg-top bg-[length:160px_50px] pt-16"

  override SignInLive do
    set :root_class, @page_root_class
  end

  override SignOutLive do
    set :root_class, @page_root_class
  end

  override ConfirmLive do
    set :root_class, @page_root_class
  end

  override ResetLive do
    set :root_class, @page_root_class
  end

  override Components.SignIn do
    set :root_class, "w-full flex flex-col items-center gap-4"
    set :strategy_class, @card_class
    set :show_banner, true
    set :authentication_error_container_class, "alert alert-error w-full max-w-sm"
    set :authentication_error_text_class, "text-sm"
  end

  override Components.Confirm do
    set :root_class, "w-full flex flex-col items-center gap-4"
    set :strategy_class, @card_class
    set :show_banner, true
  end

  override Components.Reset do
    set :root_class, "w-full flex flex-col items-center gap-4"
    set :strategy_class, @card_class
    set :show_banner, true
  end

  override Components.Banner do
    set :root_class, "w-full flex justify-center"
    set :href_class, nil
    set :href_url, "/"
    set :image_class, "h-24 w-auto"
    set :dark_image_class, "hidden"
    set :image_url, "/images/secant-service.svg"
    set :dark_image_url, nil
    set :text_class, nil
    set :text, nil
  end

  override Components.Password do
    set :root_class, "card-body"
    set :interstitial_class, "flex flex-row justify-between text-sm mt-2"
    set :toggler_class, @toggler_class
  end

  override Components.Password.SignInForm do
    set :label_class, @heading_class
    set :slot_class, "my-2"
  end

  override Components.Password.RegisterForm do
    set :label_class, @heading_class
    set :slot_class, "my-2"
  end

  override Components.Password.ResetForm do
    set :label_class, @heading_class
    set :slot_class, "my-2"
  end

  override Components.Password.Input do
    set :field_class, "fieldset mb-2"
    set :label_class, "label mb-1"
    set :input_class, "input w-full"
    set :input_class_with_error, "input input-error w-full"
    set :submit_class, @submit_class
    set :error_ul, "mt-1 flex flex-col gap-1"
    set :error_li, "text-error text-sm"
    set :remember_me_class, "flex items-center gap-2 mt-2 mb-2"
    set :checkbox_class, "checkbox checkbox-sm"
    set :checkbox_label_class, "label"
  end

  override Components.Confirm.Form do
    set :root_class, "card-body items-center text-center"
    set :label_class, @heading_class
  end

  override Components.Confirm.Input do
    set :submit_class, @submit_class
  end

  override Components.Reset.Form do
    set :root_class, "card-body"
    set :label_class, @heading_class
    set :spacer_class, "py-1"
  end

  override Components.SignOut do
    set :root_class, @card_class <> " card-body items-center text-center " <> @logo_bg_class
    set :h2_class, "card-title text-2xl justify-center mb-2"
    set :info_text_class, "text-base-content/70 mb-4"
    set :button_class, "btn btn-primary w-full"
  end
end
