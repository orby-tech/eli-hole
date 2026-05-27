defmodule EliHole.DNS.ProvidersTest do
  use EliHole.DataCase

  alias EliHole.DNS.Providers
  alias EliHole.DNS.Provider

  defp valid_attrs(overrides) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        "name" => "Test Provider #{unique}",
        "ip" => "10.0.0.#{rem(unique, 255)}",
        "port" => 53,
        "enabled" => true,
        "position" => unique
      },
      overrides
    )
  end

  describe "create/1" do
    test "creates a provider with valid attributes" do
      attrs = valid_attrs(%{"ip" => "192.168.1.1", "port" => 53})
      assert {:ok, %Provider{} = provider} = Providers.create(attrs)
      assert provider.ip == "192.168.1.1"
      assert provider.port == 53
      assert provider.enabled == true
    end

    test "auto-increments position based on existing max" do
      attrs1 = valid_attrs(%{"ip" => "172.16.0.1", "port" => 53})
      {:ok, p1} = Providers.create(attrs1)

      attrs2 = valid_attrs(%{"ip" => "172.16.0.2", "port" => 53})
      {:ok, p2} = Providers.create(attrs2)

      assert p2.position > p1.position
    end

    test "fails with invalid IP" do
      attrs = valid_attrs(%{"ip" => "999.999.999.999"})
      assert {:error, changeset} = Providers.create(attrs)
      assert %{ip: _} = errors_on(changeset)
    end

    test "fails without required fields" do
      assert {:error, changeset} = Providers.create(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :ip)
    end
  end

  describe "list_all/0" do
    test "returns all providers ordered by position" do
      {:ok, _p1} = Providers.create(valid_attrs(%{"ip" => "10.10.1.1", "port" => 5301}))
      {:ok, _p2} = Providers.create(valid_attrs(%{"ip" => "10.10.1.2", "port" => 5302}))

      all = Providers.list_all()
      assert length(all) >= 2

      positions = Enum.map(all, & &1.position)
      assert positions == Enum.sort(positions)
    end
  end

  describe "list_enabled/0" do
    test "returns only enabled providers" do
      {:ok, _enabled} =
        Providers.create(valid_attrs(%{"ip" => "10.20.1.1", "port" => 5303, "enabled" => true}))

      {:ok, disabled} =
        Providers.create(valid_attrs(%{"ip" => "10.20.1.2", "port" => 5304, "enabled" => false}))

      enabled_list = Providers.list_enabled()
      enabled_ids = Enum.map(enabled_list, & &1.id)
      refute disabled.id in enabled_ids
    end
  end

  describe "update/2" do
    test "updates provider attributes" do
      {:ok, provider} =
        Providers.create(
          valid_attrs(%{"ip" => "10.30.1.1", "port" => 5305, "name" => "Old Name"})
        )

      {:ok, updated} = Providers.update(provider, %{"name" => "New Name"})
      assert updated.name == "New Name"
    end

    test "fails with invalid attributes" do
      {:ok, provider} = Providers.create(valid_attrs(%{"ip" => "10.30.1.2", "port" => 5306}))
      assert {:error, _changeset} = Providers.update(provider, %{"port" => -1})
    end
  end

  describe "delete/1" do
    test "removes the provider" do
      {:ok, provider} = Providers.create(valid_attrs(%{"ip" => "10.40.1.1", "port" => 5307}))
      assert {:ok, _} = Providers.delete(provider)
      assert_raise Ecto.NoResultsError, fn -> Providers.get!(provider.id) end
    end
  end

  describe "to_tuples/1" do
    test "converts providers to {ip_tuple, port} format" do
      {:ok, provider} = Providers.create(valid_attrs(%{"ip" => "10.50.1.1", "port" => 5308}))
      tuples = Providers.to_tuples([provider])
      assert [{{10, 50, 1, 1}, 5308}] = tuples
    end

    test "returns empty list for empty input" do
      assert Providers.to_tuples([]) == []
    end
  end

  describe "seed_defaults/0" do
    test "creates default Google DNS providers" do
      Providers.seed_defaults()

      all = Providers.list_all()
      ips = Enum.map(all, & &1.ip)
      assert "8.8.8.8" in ips
      assert "8.8.4.4" in ips
    end

    test "is idempotent (second call does not duplicate)" do
      Providers.seed_defaults()
      count_before = length(Providers.list_all())

      Providers.seed_defaults()
      count_after = length(Providers.list_all())

      assert count_after == count_before
    end
  end
end
