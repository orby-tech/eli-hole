defmodule EliHoleWeb.SessionController do
  use EliHoleWeb, :controller

  alias EliHole.Accounts

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        conn
        |> put_session(:admin_user_id, user.id)
        |> redirect(to: "/admin/queries")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid username or password")
        |> redirect(to: "/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:admin_user_id)
    |> redirect(to: "/login")
  end
end
