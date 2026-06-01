defmodule EliHole.DNS.AdlistsTest do
  use EliHole.DataCase

  alias EliHole.DNS.{Adlist, Adlists, Blocklist, BlocklistEntry}

  setup do
    Repo.delete_all(Adlist)
    Repo.delete_all(BlocklistEntry)
    Blocklist.flush_cache()
    :ok
  end

  describe "Adlist.changeset/2" do
    test "valid with an http url" do
      changeset = Adlist.changeset(%Adlist{}, %{address: "http://example.com/list.txt"})
      assert changeset.valid?
    end

    test "valid with an https url" do
      changeset = Adlist.changeset(%Adlist{}, %{address: "https://example.com/list.txt"})
      assert changeset.valid?
    end

    test "requires address" do
      changeset = Adlist.changeset(%Adlist{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).address
    end

    test "rejects non-http(s) url" do
      changeset = Adlist.changeset(%Adlist{}, %{address: "ftp://example.com/list.txt"})
      refute changeset.valid?
      assert "must be an HTTP(S) URL" in errors_on(changeset).address
    end

    test "rejects bare domain without scheme" do
      changeset = Adlist.changeset(%Adlist{}, %{address: "example.com/list.txt"})
      refute changeset.valid?
      assert "must be an HTTP(S) URL" in errors_on(changeset).address
    end

    test "enabled defaults to true" do
      assert %Adlist{}.enabled == true
    end

    test "domain_count defaults to 0" do
      assert %Adlist{}.domain_count == 0
    end

    test "casts comment and enabled" do
      changeset =
        Adlist.changeset(%Adlist{}, %{
          address: "https://example.com/list.txt",
          comment: "ads",
          enabled: false
        })

      assert changeset.valid?
      assert get_change(changeset, :comment) == "ads"
      assert get_change(changeset, :enabled) == false
    end

    test "does not cast domain_count or last_updated_at" do
      changeset =
        Adlist.changeset(%Adlist{}, %{
          address: "https://example.com/list.txt",
          domain_count: 999,
          last_updated_at: DateTime.utc_now()
        })

      assert get_change(changeset, :domain_count) == nil
      assert get_change(changeset, :last_updated_at) == nil
    end
  end

  describe "create/1" do
    test "persists a valid adlist with defaults" do
      assert {:ok, adlist} = Adlists.create(%{address: "https://example.com/a.txt"})
      assert adlist.address == "https://example.com/a.txt"
      assert adlist.enabled == true
      assert adlist.domain_count == 0
    end

    test "returns an error changeset for invalid url" do
      assert {:error, changeset} = Adlists.create(%{address: "not-a-url"})
      assert "must be an HTTP(S) URL" in errors_on(changeset).address
    end

    test "returns an error changeset when address is missing" do
      assert {:error, changeset} = Adlists.create(%{comment: "x"})
      assert "can't be blank" in errors_on(changeset).address
    end

    test "enforces unique address" do
      assert {:ok, _} = Adlists.create(%{address: "https://dup.example.com/a.txt"})
      assert {:error, changeset} = Adlists.create(%{address: "https://dup.example.com/a.txt"})
      assert "has already been taken" in errors_on(changeset).address
    end

    test "broadcasts change on success" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:adlists")
      assert {:ok, _} = Adlists.create(%{address: "https://example.com/b.txt"})
      assert_receive :adlists_changed
    end

    test "does not broadcast on failure" do
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:adlists")
      assert {:error, _} = Adlists.create(%{address: "bad"})
      refute_receive :adlists_changed, 50
    end
  end

  describe "list_all/1 and list_enabled/0" do
    test "list_all returns every adlist ordered by inserted_at" do
      {:ok, _} = Adlists.create(%{address: "https://a.example.com/x.txt"})
      {:ok, _} = Adlists.create(%{address: "https://b.example.com/x.txt"})

      addresses = Adlists.list_all() |> Enum.map(& &1.address)
      assert "https://a.example.com/x.txt" in addresses
      assert "https://b.example.com/x.txt" in addresses
      assert length(addresses) == 2
    end

    test "list_enabled excludes disabled adlists" do
      {:ok, on} = Adlists.create(%{address: "https://on.example.com/x.txt"})
      {:ok, off} = Adlists.create(%{address: "https://off.example.com/x.txt"})
      {:ok, _} = Adlists.update(off, %{enabled: false})

      enabled = Adlists.list_enabled()
      assert length(enabled) == 1
      assert hd(enabled).id == on.id
    end

    test "list_all is empty with no adlists" do
      assert Adlists.list_all() == []
    end
  end

  describe "get!/1" do
    test "fetches an existing adlist" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/get.txt"})
      assert Adlists.get!(adlist.id).id == adlist.id
    end

    test "raises for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Adlists.get!(-1) end
    end
  end

  describe "update/2" do
    test "updates fields" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/u.txt"})
      assert {:ok, updated} = Adlists.update(adlist, %{comment: "new comment", enabled: false})
      assert updated.comment == "new comment"
      assert updated.enabled == false
    end

    test "returns an error changeset for invalid update" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/u2.txt"})
      assert {:error, changeset} = Adlists.update(adlist, %{address: "nope"})
      assert "must be an HTTP(S) URL" in errors_on(changeset).address
    end

    test "broadcasts change on success" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/u3.txt"})
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:adlists")
      assert {:ok, _} = Adlists.update(adlist, %{comment: "c"})
      assert_receive :adlists_changed
    end
  end

  describe "delete/1" do
    test "removes the adlist" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/d.txt"})
      assert {:ok, _} = Adlists.delete(adlist)
      assert Adlists.list_all() == []
    end

    test "removes the adlist's gravity blocklist entries" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/d2.txt"})
      source = "gravity:#{adlist.id}"

      Repo.insert!(%BlocklistEntry{domain: "ads.example.com", type: "exact", source: source})
      Repo.insert!(%BlocklistEntry{domain: "other.example.com", type: "exact", source: "manual"})

      assert {:ok, _} = Adlists.delete(adlist)

      remaining = Repo.all(from e in BlocklistEntry, select: e.source)
      refute source in remaining
      assert "manual" in remaining
    end

    test "broadcasts change" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/d3.txt"})
      Phoenix.PubSub.subscribe(EliHole.PubSub, "dns:adlists")
      assert {:ok, _} = Adlists.delete(adlist)
      assert_receive :adlists_changed
    end
  end

  describe "update_stats/2" do
    test "sets domain_count and last_updated_at" do
      {:ok, adlist} = Adlists.create(%{address: "https://example.com/s.txt"})
      assert adlist.last_updated_at == nil

      assert {:ok, updated} = Adlists.update_stats(adlist, 1234)
      assert updated.domain_count == 1234
      assert %DateTime{} = updated.last_updated_at
    end
  end

  describe "stats/0" do
    test "counts total, enabled and sums enabled domain counts" do
      {:ok, a} = Adlists.create(%{address: "https://a.example.com/s.txt"})
      {:ok, b} = Adlists.create(%{address: "https://b.example.com/s.txt"})
      {:ok, c} = Adlists.create(%{address: "https://c.example.com/s.txt"})

      {:ok, _} = Adlists.update_stats(a, 100)
      {:ok, _} = Adlists.update_stats(b, 50)
      {:ok, _} = Adlists.update_stats(c, 999)
      {:ok, _} = Adlists.update(c, %{enabled: false})

      stats = Adlists.stats()
      assert stats.total == 3
      assert stats.enabled == 2
      # disabled list (c, 999) is excluded from the domain sum
      assert stats.total_domains == 150
    end

    test "returns zeros with no adlists" do
      assert Adlists.stats() == %{total: 0, enabled: 0, total_domains: 0}
    end
  end
end
