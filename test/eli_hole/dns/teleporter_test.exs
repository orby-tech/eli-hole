defmodule EliHole.DNS.TeleporterTest do
  use EliHole.DataCase

  alias EliHole.DNS.Teleporter

  alias EliHole.DNS.{
    BlocklistEntry,
    LocalDNS,
    LocalRecord,
    Provider,
    WhitelistEntry
  }

  setup do
    Repo.delete_all(BlocklistEntry)
    Repo.delete_all(WhitelistEntry)
    Repo.delete_all(LocalRecord)
    Repo.delete_all(Provider)
    LocalDNS.flush_cache()
    :ok
  end

  # --- helpers ---

  defp insert_blocklist(domain, type, attrs \\ %{}) do
    %BlocklistEntry{}
    |> BlocklistEntry.changeset(
      Map.merge(%{"domain" => domain, "type" => type, "source" => "manual"}, attrs)
    )
    |> Repo.insert!()
  end

  defp insert_whitelist(domain, type, attrs \\ %{}) do
    %WhitelistEntry{}
    |> WhitelistEntry.changeset(
      Map.merge(%{"domain" => domain, "type" => type, "source" => "manual"}, attrs)
    )
    |> Repo.insert!()
  end

  defp insert_provider(name, ip, port) do
    %Provider{}
    |> Provider.changeset(%{"name" => name, "ip" => ip, "port" => port})
    |> Repo.insert!()
  end

  defp insert_local(domain, type, target) do
    %LocalRecord{}
    |> LocalRecord.changeset(%{"domain" => domain, "record_type" => type, "target" => target})
    |> Repo.insert!()
  end

  # Build a tar.gz binary from a list of {name, content} pairs.
  #
  # OTP's `:erl_tar.create/3` has no in-memory `{:binary, []}` write device, so
  # we stage files in a temp dir and tar from real paths, then clean up.
  defp build_tar(files) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "teleporter_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    try do
      tar_files =
        Enum.map(files, fn {name, content} ->
          path = Path.join(tmp_dir, name)
          File.write!(path, content)
          {String.to_charlist(name), String.to_charlist(path)}
        end)

      tar_path = Path.join(tmp_dir, "archive.tar.gz")
      :ok = :erl_tar.create(String.to_charlist(tar_path), tar_files, [:compressed])
      File.read!(tar_path)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp tar_contents(tar_binary) do
    {:ok, file_list} = :erl_tar.extract({:binary, tar_binary}, [:memory, :compressed])
    Map.new(file_list, fn {name, content} -> {List.to_string(name), content} end)
  end

  # ------------------------------------------------------------------
  # export/0
  # ------------------------------------------------------------------

  describe "export/0" do
    test "returns a gzip tar binary with all expected files" do
      assert {:ok, tar} = Teleporter.export()
      assert is_binary(tar)

      files = tar_contents(tar)

      for name <- ~w(blocklist_exact.json blocklist_wildcard.json blocklist_regex.json
                     whitelist_exact.json whitelist_wildcard.json whitelist_regex.json
                     providers.json local_dns.json) do
        assert Map.has_key?(files, name), "missing #{name}"
      end
    end

    test "empty DB exports empty json arrays" do
      files = tar_contents(elem(Teleporter.export(), 1))

      assert Jason.decode!(files["blocklist_exact.json"]) == []
      assert Jason.decode!(files["whitelist_regex.json"]) == []
      assert Jason.decode!(files["providers.json"]) == []
      assert Jason.decode!(files["local_dns.json"]) == []
    end

    test "exported data matches DB state and is split by type" do
      insert_blocklist("blocked-exact.com", "exact", %{"comment" => "bad"})
      insert_blocklist("*.blocked-wild.com", "wildcard")
      insert_blocklist(".*regex.*", "regex")
      insert_whitelist("allow.com", "exact")
      insert_provider("MyDNS", "1.1.1.1", 53)
      insert_local("home.lan", "A", "192.168.1.10")

      files = tar_contents(elem(Teleporter.export(), 1))

      assert [%{"domain" => "blocked-exact.com", "type" => "exact", "comment" => "bad"}] =
               Jason.decode!(files["blocklist_exact.json"])

      assert [%{"domain" => "*.blocked-wild.com", "type" => "wildcard"}] =
               Jason.decode!(files["blocklist_wildcard.json"])

      assert [%{"domain" => ".*regex.*", "type" => "regex"}] =
               Jason.decode!(files["blocklist_regex.json"])

      assert [%{"domain" => "allow.com"}] = Jason.decode!(files["whitelist_exact.json"])

      assert [%{"name" => "MyDNS", "ip" => "1.1.1.1", "port" => 53}] =
               Jason.decode!(files["providers.json"])

      assert [%{"domain" => "home.lan", "record_type" => "A", "target" => "192.168.1.10"}] =
               Jason.decode!(files["local_dns.json"])
    end
  end

  # ------------------------------------------------------------------
  # detect_format/1
  # ------------------------------------------------------------------

  describe "detect_format/1" do
    test "detects EliHole's own export" do
      {:ok, tar} = Teleporter.export()
      assert Teleporter.detect_format(tar) == :elihole
    end

    test "detects pihole format via blacklist.exact.json" do
      tar = build_tar([{"blacklist.exact.json", "[]"}])
      assert Teleporter.detect_format(tar) == :pihole
    end

    test "detects pihole format via setupVars.conf" do
      tar = build_tar([{"setupVars.conf", "PIHOLE_DNS_1=8.8.8.8\n"}])
      assert Teleporter.detect_format(tar) == :pihole
    end

    test "detects elihole format via providers.json" do
      tar = build_tar([{"providers.json", "[]"}])
      assert Teleporter.detect_format(tar) == :elihole
    end

    test "returns :unknown for an unrecognized archive" do
      tar = build_tar([{"random.txt", "hello"}])
      assert Teleporter.detect_format(tar) == :unknown
    end

    test "returns :unknown for malformed (non-tar) input" do
      assert Teleporter.detect_format("not a tar") == :unknown
    end
  end

  # ------------------------------------------------------------------
  # import_elihole/1 — round-trip
  # ------------------------------------------------------------------

  describe "import_elihole/1 round-trip" do
    test "restores blocklist, whitelist, providers and local DNS from an export" do
      insert_blocklist("ads.example.com", "exact", %{"comment" => "ads"})
      insert_blocklist("*.tracker.com", "wildcard")
      insert_blocklist("ev[il]\\.net", "regex")
      insert_whitelist("safe.example.com", "exact")
      insert_whitelist("*.cdn.com", "wildcard")
      insert_provider("Cloudflare", "1.1.1.1", 53)
      insert_local("nas.lan", "A", "10.0.0.5")
      insert_local("ipv6.lan", "AAAA", "::1")

      {:ok, tar} = Teleporter.export()

      # Wipe DB, then re-import.
      Repo.delete_all(BlocklistEntry)
      Repo.delete_all(WhitelistEntry)
      Repo.delete_all(Provider)
      Repo.delete_all(LocalRecord)

      assert {:ok, summary} = Teleporter.import_elihole(tar)

      assert summary.blocklist == 3
      assert summary.whitelist == 2
      assert summary.providers == 1
      assert summary.local_dns == 2

      assert Repo.aggregate(BlocklistEntry, :count) == 3
      assert Repo.aggregate(WhitelistEntry, :count) == 2
      assert Repo.aggregate(Provider, :count) == 1
      assert Repo.aggregate(LocalRecord, :count) == 2

      assert Repo.get_by(BlocklistEntry, domain: "ads.example.com", type: "exact")
      assert Repo.get_by(BlocklistEntry, domain: "*.tracker.com", type: "wildcard")
      assert Repo.get_by(WhitelistEntry, domain: "safe.example.com", type: "exact")
      assert Repo.get_by(LocalRecord, domain: "nas.lan", record_type: "A").target == "10.0.0.5"
    end

    test "preserves source and enabled flags from export" do
      insert_blocklist("src.com", "exact", %{"source" => "custom_src", "enabled" => false})
      {:ok, tar} = Teleporter.export()
      Repo.delete_all(BlocklistEntry)

      assert {:ok, _} = Teleporter.import_elihole(tar)
      entry = Repo.get_by(BlocklistEntry, domain: "src.com", type: "exact")
      assert entry.source == "custom_src"
      assert entry.enabled == false
    end

    test "is idempotent on conflicting domain+type (on_conflict: :nothing)" do
      insert_blocklist("dup.com", "exact")
      {:ok, tar} = Teleporter.export()

      assert {:ok, summary} = Teleporter.import_elihole(tar)
      assert summary.blocklist == 0
      assert Repo.aggregate(BlocklistEntry, :count) == 1
    end

    test "missing files in archive are skipped without error" do
      tar = build_tar([{"blocklist_exact.json", ~s([{"domain":"only.com","enabled":true}])}])

      assert {:ok, summary} = Teleporter.import_elihole(tar)
      assert summary.blocklist == 1
      assert summary.whitelist == 0
      assert summary.providers == 0
      assert summary.local_dns == 0
    end

    test "whitelist defaults enabled to true when flag absent" do
      tar = build_tar([{"whitelist_exact.json", ~s([{"domain":"w.com"}])}])

      assert {:ok, _} = Teleporter.import_elihole(tar)
      assert Repo.get_by(WhitelistEntry, domain: "w.com", type: "exact").enabled == true
    end

    test "returns error tuple for malformed (non-tar) input" do
      assert {:error, msg} = Teleporter.import_elihole("garbage")
      assert msg =~ "Failed to extract tar"
    end

    test "raises on malformed JSON inside a valid archive" do
      tar = build_tar([{"providers.json", "not json"}])
      assert_raise Jason.DecodeError, fn -> Teleporter.import_elihole(tar) end
    end
  end

  # ------------------------------------------------------------------
  # import_pihole/1
  # ------------------------------------------------------------------

  describe "import_pihole/1" do
    test "imports exact + regex blacklist, only enabled entries" do
      blacklist_exact =
        Jason.encode!([
          %{"domain" => "Ads.COM", "enabled" => 1, "comment" => "x"},
          %{"domain" => "disabled.com", "enabled" => 0}
        ])

      blacklist_regex =
        Jason.encode!([%{"domain" => "ev.*", "enabled" => 1, "comment" => nil}])

      tar =
        build_tar([
          {"blacklist.exact.json", blacklist_exact},
          {"blacklist.regex.json", blacklist_regex}
        ])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.blocklist == 2

      # domain lowercased on import
      assert Repo.get_by(BlocklistEntry, domain: "ads.com", type: "exact")
      assert Repo.get_by(BlocklistEntry, domain: "ev.*", type: "regex")
      refute Repo.get_by(BlocklistEntry, domain: "disabled.com", type: "exact")
    end

    test "imports whitelist (exact + regex)" do
      tar =
        build_tar([
          {"whitelist.exact.json", Jason.encode!([%{"domain" => "Good.com", "enabled" => 1}])},
          {"whitelist.regex.json", Jason.encode!([%{"domain" => "ok.*", "enabled" => 1}])}
        ])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.whitelist == 2
      assert Repo.get_by(WhitelistEntry, domain: "good.com", type: "exact")
      assert Repo.get_by(WhitelistEntry, domain: "ok.*", type: "regex")
    end

    test "imports providers from setupVars.conf and skips existing ip/port" do
      insert_provider("Existing", "8.8.8.8", 53)

      conf = """
      PIHOLE_DNS_1=8.8.8.8
      PIHOLE_DNS_2=1.0.0.1
      WEB_PASSWORD=ignored
      """

      tar = build_tar([{"setupVars.conf", conf}])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      # 8.8.8.8 already present -> only 1.0.0.1 created
      assert summary.providers == 1
      assert Repo.get_by(Provider, ip: "1.0.0.1", port: 53)
    end

    test "imports enabled adlists from adlist.json into gravity" do
      adlist =
        Jason.encode!([
          %{"address" => "https://example.com/list.txt", "enabled" => 1, "comment" => "c"},
          %{"address" => "https://nope.com/list.txt", "enabled" => 0}
        ])

      tar = build_tar([{"adlist.json", adlist}])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.gravity == 1
    end

    test "imports custom.list into local DNS" do
      custom = """
      192.168.1.50 router.lan
      # a comment
      10.0.0.9 printer.lan
      """

      tar = build_tar([{"custom.list", custom}])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.local_dns == 2
      assert Repo.get_by(LocalRecord, domain: "router.lan", record_type: "A")
      assert Repo.get_by(LocalRecord, domain: "printer.lan", record_type: "A")
    end

    test "notes skipped clients and groups" do
      tar =
        build_tar([
          {"client.json", Jason.encode!([%{"ip" => "10.0.0.1"}])},
          {"group.json", Jason.encode!([%{"name" => "g"}])}
        ])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert "clients" in summary.skipped
      assert "groups" in summary.skipped
    end

    test "does not note empty skipped files" do
      tar = build_tar([{"client.json", "[]"}, {"group.json", ""}])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.skipped == []
    end

    test "empty pihole archive returns zero summary" do
      tar = build_tar([{"setupVars.conf", ""}])

      assert {:ok, summary} = Teleporter.import_pihole(tar)
      assert summary.blocklist == 0
      assert summary.whitelist == 0
      assert summary.providers == 0
      assert summary.gravity == 0
      assert summary.local_dns == 0
    end

    test "returns error tuple for malformed (non-tar) input" do
      assert {:error, msg} = Teleporter.import_pihole("not-a-tar-at-all")
      assert msg =~ "Failed to extract tar"
    end
  end
end
