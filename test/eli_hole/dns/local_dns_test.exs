defmodule EliHole.DNS.LocalDNSTest do
  use EliHole.DataCase

  alias EliHole.DNS.{LocalDNS, LocalRecord}

  setup do
    Repo.delete_all(LocalRecord)
    LocalDNS.flush_cache()
    :ok
  end

  # -------------------------------------------------------------------
  # LocalRecord changeset validation
  # -------------------------------------------------------------------

  describe "LocalRecord changeset" do
    test "valid A record with IPv4 target" do
      cs = LocalRecord.changeset(%LocalRecord{}, %{domain: "app.local", target: "192.168.1.1"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :record_type) == "A"
    end

    test "valid AAAA record with IPv6 target" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "AAAA",
          target: "::1"
        })

      assert cs.valid?
    end

    test "valid CNAME record with domain target" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "alias.local",
          record_type: "CNAME",
          target: "real.host.local"
        })

      assert cs.valid?
    end

    test "invalid: A record with non-IPv4 target" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "A",
          target: "not-an-ip"
        })

      refute cs.valid?
      assert errors_on(cs).target != []
    end

    test "invalid: A record with IPv6 target" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "A",
          target: "::1"
        })

      refute cs.valid?
      assert errors_on(cs).target != []
    end

    test "invalid: AAAA record with non-IP target" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "AAAA",
          target: "not-an-ip"
        })

      refute cs.valid?
      assert errors_on(cs).target != []
    end

    test "AAAA record accepts IPv4-mapped IPv6 (OTP behaviour)" do
      # :inet.parse_ipv6_address/1 accepts IPv4 addresses as IPv4-mapped IPv6
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "AAAA",
          target: "192.168.1.1"
        })

      assert cs.valid?
    end

    test "invalid: missing domain" do
      cs = LocalRecord.changeset(%LocalRecord{}, %{target: "1.2.3.4"})
      refute cs.valid?
      assert errors_on(cs).domain != []
    end

    test "invalid: missing target" do
      cs = LocalRecord.changeset(%LocalRecord{}, %{domain: "app.local"})
      refute cs.valid?
      assert errors_on(cs).target != []
    end

    test "domain normalization lowercases" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{domain: "APP.Local", target: "10.0.0.1"})

      assert Ecto.Changeset.get_change(cs, :domain) == "app.local"
    end

    test "domain normalization trims whitespace" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{domain: "  app.local  ", target: "10.0.0.1"})

      assert Ecto.Changeset.get_change(cs, :domain) == "app.local"
    end

    test "invalid record_type is rejected" do
      cs =
        LocalRecord.changeset(%LocalRecord{}, %{
          domain: "app.local",
          record_type: "MX",
          target: "10.0.0.1"
        })

      refute cs.valid?
      assert errors_on(cs).record_type != []
    end
  end

  # -------------------------------------------------------------------
  # CRUD operations
  # -------------------------------------------------------------------

  describe "create_record/1" do
    test "creates with valid attrs" do
      assert {:ok, record} =
               LocalDNS.create_record(%{domain: "new.local", target: "10.0.0.1"})

      assert record.domain == "new.local"
      assert record.target == "10.0.0.1"
      assert record.record_type == "A"
      assert record.enabled == true
    end

    test "returns error changeset with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = LocalDNS.create_record(%{domain: "", target: ""})
    end

    test "enforces unique domain+record_type constraint" do
      assert {:ok, _} = LocalDNS.create_record(%{domain: "dup.local", target: "10.0.0.1"})

      assert {:error, changeset} =
               LocalDNS.create_record(%{domain: "dup.local", target: "10.0.0.2"})

      assert errors_on(changeset).domain != [] or errors_on(changeset).record_type != []
    end
  end

  describe "list_records/1" do
    test "returns all records ordered by inserted_at desc" do
      {:ok, _} = LocalDNS.create_record(%{domain: "a.local", target: "10.0.0.1"})
      {:ok, _} = LocalDNS.create_record(%{domain: "b.local", target: "10.0.0.2"})

      records = LocalDNS.list_records()
      assert length(records) == 2
      domains = Enum.map(records, & &1.domain)
      assert "a.local" in domains
      assert "b.local" in domains
    end

    test "respects pagination" do
      for i <- 1..5 do
        LocalDNS.create_record(%{domain: "page#{i}.local", target: "10.0.0.#{i}"})
      end

      page1 = LocalDNS.list_records(page: 1, per_page: 2)
      assert length(page1) == 2

      page2 = LocalDNS.list_records(page: 2, per_page: 2)
      assert length(page2) == 2

      page3 = LocalDNS.list_records(page: 3, per_page: 2)
      assert length(page3) == 1
    end
  end

  describe "search_records/2" do
    test "filters by domain" do
      {:ok, _} = LocalDNS.create_record(%{domain: "web.example.local", target: "10.0.0.1"})
      {:ok, _} = LocalDNS.create_record(%{domain: "db.other.local", target: "10.0.0.2"})

      results = LocalDNS.search_records("example")
      assert length(results) == 1
      assert hd(results).domain == "web.example.local"
    end

    test "filters by target" do
      {:ok, _} = LocalDNS.create_record(%{domain: "a.local", target: "192.168.1.1"})
      {:ok, _} = LocalDNS.create_record(%{domain: "b.local", target: "10.0.0.1"})

      results = LocalDNS.search_records("192.168")
      assert length(results) == 1
      assert hd(results).target == "192.168.1.1"
    end

    test "search is case-insensitive" do
      {:ok, _} = LocalDNS.create_record(%{domain: "myhost.local", target: "10.0.0.1"})

      assert length(LocalDNS.search_records("MYHOST")) == 1
    end
  end

  describe "count_records/1" do
    test "returns total count with empty search" do
      {:ok, _} = LocalDNS.create_record(%{domain: "a.local", target: "10.0.0.1"})
      {:ok, _} = LocalDNS.create_record(%{domain: "b.local", target: "10.0.0.2"})

      assert LocalDNS.count_records("") == 2
    end

    test "returns filtered count with search query" do
      {:ok, _} = LocalDNS.create_record(%{domain: "web.local", target: "10.0.0.1"})
      {:ok, _} = LocalDNS.create_record(%{domain: "db.local", target: "10.0.0.2"})

      assert LocalDNS.count_records("web") == 1
    end
  end

  describe "update_record/2" do
    test "updates target" do
      {:ok, record} = LocalDNS.create_record(%{domain: "upd.local", target: "10.0.0.1"})

      assert {:ok, updated} = LocalDNS.update_record(record, %{target: "10.0.0.99"})
      assert updated.target == "10.0.0.99"
    end

    test "toggles enabled flag" do
      {:ok, record} = LocalDNS.create_record(%{domain: "toggle.local", target: "10.0.0.1"})
      assert record.enabled == true

      assert {:ok, disabled} = LocalDNS.update_record(record, %{enabled: false})
      assert disabled.enabled == false

      assert {:ok, re_enabled} = LocalDNS.update_record(disabled, %{enabled: true})
      assert re_enabled.enabled == true
    end

    test "returns error for invalid update" do
      {:ok, record} = LocalDNS.create_record(%{domain: "bad.local", target: "10.0.0.1"})

      assert {:error, %Ecto.Changeset{}} =
               LocalDNS.update_record(record, %{target: "not-an-ip"})
    end
  end

  describe "delete_record/1" do
    test "removes record from DB" do
      {:ok, record} = LocalDNS.create_record(%{domain: "del.local", target: "10.0.0.1"})
      assert {:ok, _} = LocalDNS.delete_record(record)

      assert LocalDNS.list_records() == []
    end
  end

  describe "stats/0" do
    test "returns correct counts" do
      {:ok, _} = LocalDNS.create_record(%{domain: "on.local", target: "10.0.0.1"})
      {:ok, off} = LocalDNS.create_record(%{domain: "off.local", target: "10.0.0.2"})
      LocalDNS.update_record(off, %{enabled: false})

      stats = LocalDNS.stats()
      assert stats.total == 2
      assert stats.enabled == 1
      assert stats.disabled == 1
    end
  end

  # -------------------------------------------------------------------
  # ETS lookup
  # -------------------------------------------------------------------

  describe "lookup/2" do
    test "returns {:ok, target} for enabled record" do
      {:ok, _} = LocalDNS.create_record(%{domain: "ets.local", target: "10.0.0.1"})

      assert {:ok, "10.0.0.1"} = LocalDNS.lookup("ets.local", "A")
    end

    test "lookup is case-insensitive" do
      {:ok, _} = LocalDNS.create_record(%{domain: "case.local", target: "10.0.0.2"})

      assert {:ok, "10.0.0.2"} = LocalDNS.lookup("CASE.LOCAL", "A")
    end

    test "returns :miss for disabled record" do
      {:ok, record} = LocalDNS.create_record(%{domain: "dis.local", target: "10.0.0.3"})
      LocalDNS.update_record(record, %{enabled: false})

      assert :miss = LocalDNS.lookup("dis.local", "A")
    end

    test "returns :miss for nonexistent domain" do
      assert :miss = LocalDNS.lookup("nope.local", "A")
    end

    test "returns :miss for wrong record type" do
      {:ok, _} = LocalDNS.create_record(%{domain: "typed.local", target: "10.0.0.4"})

      assert :miss = LocalDNS.lookup("typed.local", "AAAA")
    end

    test "AAAA record lookup works" do
      {:ok, _} =
        LocalDNS.create_record(%{
          domain: "v6.local",
          record_type: "AAAA",
          target: "::1"
        })

      assert {:ok, "::1"} = LocalDNS.lookup("v6.local", "AAAA")
    end

    test "CNAME record lookup works" do
      {:ok, _} =
        LocalDNS.create_record(%{
          domain: "alias.local",
          record_type: "CNAME",
          target: "real.local"
        })

      assert {:ok, "real.local"} = LocalDNS.lookup("alias.local", "CNAME")
    end
  end

  # -------------------------------------------------------------------
  # import_custom_list/1
  # -------------------------------------------------------------------

  describe "import_custom_list/1" do
    test "parses 'IP domain' format" do
      content = """
      192.168.1.1 myhost.local
      10.0.0.1 other.local
      """

      {:ok, count} = LocalDNS.import_custom_list(content)
      assert count == 2

      records = LocalDNS.list_records()
      domains = Enum.map(records, & &1.domain)
      assert "myhost.local" in domains
      assert "other.local" in domains
    end

    test "skips comments and blank lines" do
      content = """
      # This is a comment
      192.168.1.1 valid.local

      # Another comment

      """

      {:ok, count} = LocalDNS.import_custom_list(content)
      assert count == 1
    end

    test "deduplicates by domain+type" do
      content = """
      192.168.1.1 dup.local
      192.168.1.2 dup.local
      """

      {:ok, count} = LocalDNS.import_custom_list(content)
      # Only one should be inserted (first wins via uniq_by)
      assert count == 1
    end

    test "detects IPv6 addresses as AAAA records" do
      content = "::1 v6host.local\n"

      {:ok, 1} = LocalDNS.import_custom_list(content)

      [record] = LocalDNS.list_records()
      assert record.record_type == "AAAA"
      assert record.target == "::1"
    end

    test "skips lines with invalid IP addresses" do
      content = """
      not-an-ip bad.local
      192.168.1.1 good.local
      """

      {:ok, count} = LocalDNS.import_custom_list(content)
      assert count == 1

      [record] = LocalDNS.list_records()
      assert record.domain == "good.local"
    end

    test "normalizes domains to lowercase" do
      content = "192.168.1.1 UPPER.Local\n"

      {:ok, 1} = LocalDNS.import_custom_list(content)

      [record] = LocalDNS.list_records()
      assert record.domain == "upper.local"
    end

    test "idempotent import does not duplicate" do
      content = "192.168.1.1 idem.local\n"

      {:ok, 1} = LocalDNS.import_custom_list(content)
      {:ok, 0} = LocalDNS.import_custom_list(content)
    end

    test "populates ETS cache after import" do
      content = "10.0.0.5 cached.local\n"

      {:ok, 1} = LocalDNS.import_custom_list(content)

      assert {:ok, "10.0.0.5"} = LocalDNS.lookup("cached.local", "A")
    end
  end

  # -------------------------------------------------------------------
  # Teleporter round-trip
  # -------------------------------------------------------------------

  describe "Teleporter round-trip" do
    alias EliHole.DNS.Teleporter

    # Build a tar.gz binary directly using :erl_tar write API (OTP 27 compatible)
    defp build_test_tar(file_map) do
      tmp_dir = System.tmp_dir!()
      tar_path = Path.join(tmp_dir, "test_export_#{System.unique_integer([:positive])}.tar.gz")

      tar_files =
        Enum.map(file_map, fn {name, content} ->
          file_path = Path.join(tmp_dir, name)
          File.write!(file_path, content)
          {String.to_charlist(name), String.to_charlist(file_path)}
        end)

      :ok = :erl_tar.create(String.to_charlist(tar_path), tar_files, [:compressed])
      tar_binary = File.read!(tar_path)

      # Cleanup temp files
      File.rm(tar_path)

      Enum.each(file_map, fn {name, _} ->
        File.rm(Path.join(tmp_dir, name))
      end)

      tar_binary
    end

    test "EliHole import restores local DNS records" do
      local_dns_json =
        Jason.encode!([
          %{
            domain: "roundtrip.local",
            record_type: "A",
            target: "10.0.0.99",
            enabled: true,
            comment: "round-trip"
          }
        ])

      tar_binary =
        build_test_tar(%{
          "blocklist_exact.json" => "[]",
          "blocklist_wildcard.json" => "[]",
          "blocklist_regex.json" => "[]",
          "providers.json" => "[]",
          "local_dns.json" => local_dns_json
        })

      # Import the backup
      {:ok, summary} = Teleporter.import_elihole(tar_binary)
      assert summary.local_dns >= 1

      records = LocalDNS.list_records()
      rec = Enum.find(records, &(&1.domain == "roundtrip.local"))
      assert rec != nil
      assert rec.target == "10.0.0.99"

      # ETS cache should be reloaded
      assert {:ok, "10.0.0.99"} = LocalDNS.lookup("roundtrip.local", "A")
    end

    test "detect_format identifies elihole backup with local_dns.json" do
      tar_binary =
        build_test_tar(%{
          "local_dns.json" => "[]"
        })

      assert Teleporter.detect_format(tar_binary) == :elihole
    end
  end
end
