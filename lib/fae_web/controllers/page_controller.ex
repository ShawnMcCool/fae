defmodule FaeWeb.PageController do
  use FaeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
