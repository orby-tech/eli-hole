defmodule EliHole.DNS.BlocklistTest do
  use EliHole.DataCase

  alias EliHole.DNS.{Blocklist, BlocklistEntry}

  setup do
    Repo.delete_all(BlocklistEntry)
    Blocklist.flush_cache()
    :ok
  end

  describe "blocked?/1" do
    test "returns false for non-blocked domain" do
      refute Blocklist.blocked?("example.com")
    end

    test "matches exact entry" do
      Blocklist.create_entry(%{"domain" => "ads.example.com", "type" => "exact"})
      assert Blocklist.blocked?("ads.example.com")
      refute Blocklist.blocked?("other.example.com")
    end

    test "exact match is case-insensitive" do
      Blocklist.create_entry(%{"domain" => "ADS.Example.COM", "type" => "exact"})
      assert Blocklist.blocked?("ads.example.com")
      assert Blocklist.blocked?("ADS.EXAMPLE.COM")
    end

    test "matches wildcard *.domain" do
      Blocklist.create_entry(%{"domain" => "*.tracker.com", "type" => "wildcard"})
      assert Blocklist.blocked?("ads.tracker.com")
      assert Blocklist.blocked?("deep.sub.tracker.com")
      refute Blocklist.blocked?("tracker.com")
    end

    test "matches regex pattern" do
      Blocklist.create_entry(%{"domain" => "^ad[sz]?\\.", "type" => "regex"})
      assert Blocklist.blocked?("ads.example.com")
      assert Blocklist.blocked?("adz.other.net")
      assert Blocklist.blocked?("ad.thing.org")
      refute Blocklist.blocked?("loading.example.com")
    end

    test "disabled entries are not matched" do
      {:ok, entry} = Blocklist.create_entry(%{"domain" => "blocked.com", "type" => "exact"})
      assert Blocklist.blocked?("blocked.com")

      Blocklist.update_entry(entry, %{enabled: false})
      refute Blocklist.blocked?("blocked.com")
    end

    test "returns false for non-binary input" do
      refute Blocklist.blocked?(nil)
    end
  end

  describe "domain_parents/1" do
    test "generates parent domains for subdomain" do
      parents = Blocklist.domain_parents("ads.track.example.com")
      assert "track.example.com" in parents
      assert "example.com" in parents
      assert "com" in parents
    end

    test "returns empty for single-label domain" do
      assert Blocklist.domain_parents("localhost") == []
    end
  end

  describe "CRUD" do
    test "create_entry with valid attrs" do
      assert {:ok, entry} = Blocklist.create_entry(%{"domain" => "test.com", "type" => "exact"})
      assert entry.domain == "test.com"
      assert entry.enabled == true
    end

    test "create_entry rejects invalid regex" do
      assert {:error, changeset} =
               Blocklist.create_entry(%{"domain" => "[invalid", "type" => "regex"})

      assert errors_on(changeset).domain != []
    end

    test "create_entry enforces unique domain+type" do
      Blocklist.create_entry(%{"domain" => "dup.com", "type" => "exact"})
      assert {:error, _} = Blocklist.create_entry(%{"domain" => "dup.com", "type" => "exact"})
    end

    test "update_entry" do
      {:ok, entry} = Blocklist.create_entry(%{"domain" => "old.com"})
      {:ok, updated} = Blocklist.update_entry(entry, %{comment: "updated"})
      assert updated.comment == "updated"
    end

    test "delete_entry" do
      {:ok, entry} = Blocklist.create_entry(%{"domain" => "del.com"})
      assert {:ok, _} = Blocklist.delete_entry(entry)
      assert Blocklist.list_entries() == []
    end

    test "get_entry!" do
      {:ok, entry} = Blocklist.create_entry(%{"domain" => "get.com"})
      found = Blocklist.get_entry!(entry.id)
      assert found.id == entry.id
    end

    test "list_entries returns all" do
      Blocklist.create_entry(%{"domain" => "a.com"})
      Blocklist.create_entry(%{"domain" => "b.com"})
      assert length(Blocklist.list_entries()) == 2
    end

    test "list_enabled filters disabled" do
      Blocklist.create_entry(%{"domain" => "on.com", "enabled" => "true"})
      {:ok, off} = Blocklist.create_entry(%{"domain" => "off.com"})
      Blocklist.update_entry(off, %{enabled: false})
      assert length(Blocklist.list_enabled()) == 1
    end

    test "stats returns correct counts" do
      Blocklist.create_entry(%{"domain" => "a.com"})
      {:ok, b} = Blocklist.create_entry(%{"domain" => "b.com"})
      Blocklist.update_entry(b, %{enabled: false})

      stats = Blocklist.stats()
      assert stats.total == 2
      assert stats.enabled == 1
      assert stats.disabled == 1
    end
  end

  describe "import" do
    test "import_hosts parses hosts file format" do
      content = """
      # Comment line
      0.0.0.0 ads.example.com
      0.0.0.0 tracker.example.com
      127.0.0.1 localhost
      """

      {:ok, count} = Blocklist.import_hosts(content)
      assert count == 2

      entries = Blocklist.list_entries()
      domains = Enum.map(entries, & &1.domain)
      assert "ads.example.com" in domains
      assert "tracker.example.com" in domains
      refute "localhost" in domains
    end

    test "import_domains parses domain list" do
      content = """
      ads.example.com
      # comment
      tracker.net

      """

      {:ok, count} = Blocklist.import_domains(content)
      assert count == 2
    end

    test "import is idempotent" do
      Blocklist.import_domains("dup.com\ndup.com")
      {:ok, 0} = Blocklist.import_domains("dup.com")
    end
  end

  describe "search_entries/1" do
    test "finds matching domains" do
      Blocklist.create_entry(%{"domain" => "ads.example.com"})
      Blocklist.create_entry(%{"domain" => "other.net"})

      results = Blocklist.search_entries("example")
      assert length(results) == 1
      assert hd(results).domain == "ads.example.com"
    end
  end
end
