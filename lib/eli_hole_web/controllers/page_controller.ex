defmodule EliHoleWeb.PageController do
  use EliHoleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
