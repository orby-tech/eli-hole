defmodule EliHole.Accounts do
  alias EliHole.Repo
  alias EliHole.Accounts.AdminUser

  def setup_complete? do
    env_admin_configured?() or Repo.exists?(AdminUser)
  end

  def ensure_env_admin do
    with username when is_binary(username) <- Application.get_env(:eli_hole, :admin_username),
         password when is_binary(password) <- Application.get_env(:eli_hole, :admin_password) do
      unless Repo.get_by(AdminUser, username: username) do
        create_admin(%{"username" => username, "password" => password})
      end
    end
  end

  def create_admin(attrs) do
    %AdminUser{}
    |> AdminUser.registration_changeset(attrs)
    |> Repo.insert()
  end

  def authenticate(username, password) do
    case Repo.get_by(AdminUser, username: username) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  defp env_admin_configured? do
    is_binary(Application.get_env(:eli_hole, :admin_username)) and
      is_binary(Application.get_env(:eli_hole, :admin_password))
  end
end
