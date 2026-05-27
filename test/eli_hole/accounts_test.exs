defmodule EliHole.AccountsTest do
  use EliHole.DataCase

  alias EliHole.Accounts
  alias EliHole.Accounts.AdminUser

  defp unique_username, do: "admin_#{System.unique_integer([:positive])}"

  describe "create_admin/1" do
    test "creates admin user with valid attributes" do
      attrs = %{"username" => unique_username(), "password" => "securepass123"}
      assert {:ok, %AdminUser{} = user} = Accounts.create_admin(attrs)
      assert user.username == attrs["username"]
      assert user.password_hash != nil
      # Virtual field should not be persisted
      refute user.password_hash == attrs["password"]
    end

    test "hashes the password" do
      attrs = %{"username" => unique_username(), "password" => "securepass123"}
      {:ok, user} = Accounts.create_admin(attrs)
      assert Bcrypt.verify_pass("securepass123", user.password_hash)
    end

    test "fails with short username" do
      attrs = %{"username" => "ab", "password" => "securepass123"}
      assert {:error, changeset} = Accounts.create_admin(attrs)
      assert %{username: _} = errors_on(changeset)
    end

    test "fails with short password" do
      attrs = %{"username" => unique_username(), "password" => "short"}
      assert {:error, changeset} = Accounts.create_admin(attrs)
      assert %{password: _} = errors_on(changeset)
    end

    test "fails without required fields" do
      assert {:error, changeset} = Accounts.create_admin(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :username)
      assert Map.has_key?(errors, :password)
    end

    test "enforces unique username" do
      username = unique_username()
      attrs = %{"username" => username, "password" => "securepass123"}
      {:ok, _} = Accounts.create_admin(attrs)

      assert {:error, changeset} = Accounts.create_admin(attrs)
      assert %{username: _} = errors_on(changeset)
    end
  end

  describe "authenticate/2" do
    test "returns {:ok, user} with correct credentials" do
      username = unique_username()

      {:ok, _user} =
        Accounts.create_admin(%{"username" => username, "password" => "correctpass1"})

      assert {:ok, %AdminUser{} = user} = Accounts.authenticate(username, "correctpass1")
      assert user.username == username
    end

    test "returns {:error, :invalid_credentials} with wrong password" do
      username = unique_username()
      {:ok, _} = Accounts.create_admin(%{"username" => username, "password" => "correctpass1"})

      assert {:error, :invalid_credentials} = Accounts.authenticate(username, "wrongpassword")
    end

    test "returns {:error, :invalid_credentials} with non-existent username" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("no_such_user_#{System.unique_integer()}", "anypassword")
    end
  end

  describe "setup_complete?/0" do
    test "returns true when an admin user exists in the database" do
      Accounts.create_admin(%{"username" => unique_username(), "password" => "securepass123"})
      assert Accounts.setup_complete?()
    end
  end
end
