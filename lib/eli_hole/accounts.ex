defmodule EliHole.Accounts do
  alias EliHole.Repo
  alias EliHole.Accounts.AdminUser

  def setup_complete? do
    Repo.exists?(AdminUser)
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
end
