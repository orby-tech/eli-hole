defmodule EliHoleWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      !EliHole.Accounts.setup_complete?() ->
        conn
        |> redirect(to: "/setup")
        |> halt()

      get_session(conn, :admin_user_id) ->
        conn

      true ->
        conn
        |> redirect(to: "/login")
        |> halt()
    end
  end
end
