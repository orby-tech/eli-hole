defmodule EliHole.DNS.WhitelistTest do
  use EliHole.DataCase

  alias EliHole.DNS.{Whitelist, WhitelistEntry}

  setup do
    Repo.delete_all(WhitelistEntry)
    Whitelist.flush_cache()
    :ok
  end

  describe "allowed?/1" do
    test "returns false when no entries" do
      refute Whitelist.allowed?("example.com")
    end

    test "exact match" do
      Whitelist.create_entry(%{"domain" => "cdn.example.com", "type" => "exact"})
      assert Whitelist.allowed?("cdn.example.com")
      refute Whitelist.allowed?("other.example.com")
    end

    test "case-insensitive" do
      Whitelist.create_entry(%{"domain" => "CDN.Example.COM", "type" => "exact"})
      assert Whitelist.allowed?("cdn.example.com")
      assert Whitelist.allowed?("CDN.EXAMPLE.COM")
    end

    test "wildcard match" do
      Whitelist.create_entry(%{"domain" => "*.assets.com", "type" => "wildcard"})
      assert Whitelist.allowed?("img.assets.com")
      assert Whitelist.allowed?("deep.sub.assets.com")
      refute Whitelist.allowed?("assets.com")
    end

    test "regex match" do
      Whitelist.create_entry(%{"domain" => "^cdn[0-9]?\\.", "type" => "regex"})
      assert Whitelist.allowed?("cdn.example.com")
      assert Whitelist.allowed?("cdn1.other.net")
      refute Whitelist.allowed?("ads.example.com")
    end

    test "disabled entry does not match" do
      {:ok, entry} = Whitelist.create_entry(%{"domain" => "allowed.com", "type" => "exact"})
      assert Whitelist.allowed?("allowed.com")

      Whitelist.update_entry(entry, %{enabled: false})
      refute Whitelist.allowed?("allowed.com")
    end

    test "returns false for nil" do
      refute Whitelist.allowed?(nil)
    end
  end

  describe "CRUD" do
    test "create/update/delete" do
      assert {:ok, entry} = Whitelist.create_entry(%{"domain" => "a.com", "type" => "exact"})
      assert {:ok, updated} = Whitelist.update_entry(entry, %{comment: "keep"})
      assert updated.comment == "keep"
      assert {:ok, _} = Whitelist.delete_entry(updated)
      assert Whitelist.list_entries() == []
    end

    test "rejects invalid regex" do
      assert {:error, changeset} =
               Whitelist.create_entry(%{"domain" => "[invalid", "type" => "regex"})

      assert "is not a valid regex pattern" in errors_on(changeset).domain
    end

    test "unique on domain+type" do
      Whitelist.create_entry(%{"domain" => "dup.com", "type" => "exact"})
      assert {:error, _} = Whitelist.create_entry(%{"domain" => "dup.com", "type" => "exact"})
    end
  end

  describe "import_domains/1" do
    test "imports newline-separated domains" do
      {:ok, count} = Whitelist.import_domains("a.com\nb.com\n# comment\n")
      assert count == 2
      assert Whitelist.allowed?("a.com")
      assert Whitelist.allowed?("b.com")
    end

    test "deduplicates against existing" do
      Whitelist.import_domains("dup.com")
      {:ok, 0} = Whitelist.import_domains("dup.com")
    end
  end

  describe "stats/0" do
    test "counts enabled and disabled" do
      Whitelist.create_entry(%{"domain" => "on.com"})
      {:ok, off} = Whitelist.create_entry(%{"domain" => "off.com"})
      Whitelist.update_entry(off, %{enabled: false})

      stats = Whitelist.stats()
      assert stats.total == 2
      assert stats.enabled == 1
      assert stats.disabled == 1
    end
  end
end
