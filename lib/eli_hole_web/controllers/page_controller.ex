defmodule EliHoleWeb.PageController do
  use EliHoleWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/admin")
  end
end
