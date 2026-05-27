defmodule EliHoleWeb.Plugs.RedirectIfAuthed do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :admin_user_id) do
      conn
      |> redirect(to: "/admin/queries")
      |> halt()
    else
      conn
    end
  end
end
