defmodule SecantServiceWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SecantServiceWeb, :html

  embed_templates "page_html/*"

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true, doc: "names the link, which shows only a logo"
  slot :inner_block, required: true

  @doc "A square link around a brand logo, as on the source cards."
  def brand_link(assigns) do
    ~H"""
    <a
      id={@id}
      href={@href}
      aria-label={@label}
      title={@label}
      class="inline-flex size-11 items-center justify-center rounded-field text-muted transition-colors hover:bg-base-300 hover:text-base-content"
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  attr :class, :string, default: nil

  @doc "The GitHub mark, in the current text colour."
  def github_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} fill="currentColor" aria-hidden="true">
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
    """
  end

  attr :class, :string, default: nil

  @doc "The hex.pm mark (six segments of a hexagon), in the current text colour."
  def hex_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 136 120" class={@class} fill="currentColor" aria-hidden="true">
      <path d="M57.2506 33.6721H78.2332C79.6228 33.6721 80.8734 34.0878 82.124 34.642L101.022 1.10854C99.4938 0.415704 97.8263 0 96.0198 0H39.464C37.3796 0 35.4342 0.554273 33.7667 1.52425L53.0819 34.642C54.3325 33.9492 55.7221 33.6721 57.2506 33.6721Z" />
      <path d="M85.4591 37.829L95.8809 55.8428C96.5757 57.0899 96.9926 58.6142 96.9926 59.9999L135.623 60C135.623 58.0601 134.928 56.1199 133.955 54.4571L105.747 5.54258C104.635 3.60262 102.968 2.07838 101.022 1.1084L82.1183 34.6328C83.5079 35.4643 84.6254 36.4433 85.4591 37.829Z" />
      <path d="M96.9925 60C96.9925 61.3857 96.5756 62.9099 95.8808 64.157L85.459 82.1709C84.7642 83.418 83.6526 84.5266 82.5409 85.2194L101.856 118.337C103.385 117.367 104.774 115.982 105.747 114.457L134.094 65.5427C135.067 63.8799 135.623 61.94 135.623 60H96.9925Z" />
      <path d="M78.2333 86.3283H57.2507C55.8611 86.3283 54.6055 86.049 53.4938 85.4947L34.5991 118.893C36.1277 119.586 37.6576 120 39.3251 120H96.0199C98.1043 120 100.199 119.439 101.867 118.331L82.541 85.2197C81.1514 85.9126 79.7619 86.3283 78.2333 86.3283Z" />
      <path d="M39.603 55.8431L50.0248 37.8293C50.7196 36.5821 51.972 35.3231 53.0837 34.6303L33.7668 1.52441C32.2382 2.49439 30.8486 3.88007 29.8759 5.54289L1.52854 54.4574C0.555831 56.1203 0 58.0602 0 60.0002H38.4913C38.4913 58.6145 38.9082 57.0902 39.603 55.8431Z" />
      <path d="M50.0248 82.1709L39.603 64.157C38.9082 62.9099 38.4913 61.3857 38.4913 60H0C0 61.94 0.555831 63.8799 1.52854 65.5427L29.8759 114.457C30.9876 116.397 32.6551 117.921 34.6005 118.891L53.4988 85.4965C51.9702 84.6651 50.8586 83.5566 50.0248 82.1709Z" />
    </svg>
    """
  end
end
