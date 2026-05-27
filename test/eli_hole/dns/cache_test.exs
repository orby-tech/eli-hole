defmodule EliHole.DNS.CacheTest do
  use EliHole.DataCase

  alias EliHole.DNS.Cache

  describe "lookup/2" do
    test "returns :miss when key does not exist" do
      assert :miss = Cache.lookup("nonexistent-#{System.unique_integer()}.test", "A")
    end

    test "returns {:hit, response, upstream} after put" do
      domain = "cache-hit-#{System.unique_integer()}.test"
      Cache.put(domain, "A", <<1, 2, 3>>, "8.8.8.8:53")
      assert {:hit, <<1, 2, 3>>, "8.8.8.8:53"} = Cache.lookup(domain, "A")
    end

    test "different types are independent keys" do
      domain = "multi-type-#{System.unique_integer()}.test"
      Cache.put(domain, "A", <<1>>, "8.8.8.8:53")
      Cache.put(domain, "AAAA", <<2>>, "1.1.1.1:53")

      assert {:hit, <<1>>, "8.8.8.8:53"} = Cache.lookup(domain, "A")
      assert {:hit, <<2>>, "1.1.1.1:53"} = Cache.lookup(domain, "AAAA")
    end
  end

  describe "TTL expiry" do
    test "entry expires after TTL passes" do
      domain = "ttl-expire-#{System.unique_integer()}.test"
      original_ttl = Cache.get_ttl()

      # Set TTL to 0 so entry is immediately expired
      Cache.set_ttl(0)
      Cache.put(domain, "A", <<1, 2, 3>>, "8.8.8.8:53")
      assert :miss = Cache.lookup(domain, "A")

      # Restore
      Cache.set_ttl(original_ttl)
    end
  end

  describe "get_ttl/0 and set_ttl/1" do
    test "set_ttl changes the value returned by get_ttl" do
      original = Cache.get_ttl()
      Cache.set_ttl(600)
      assert Cache.get_ttl() == 600
      Cache.set_ttl(original)
    end

    test "set_ttl persists to dns_settings table" do
      original = Cache.get_ttl()
      Cache.set_ttl(999)

      setting = Repo.get_by(EliHole.DNS.Setting, key: "ttl")
      assert setting.value == "999"

      Cache.set_ttl(original)
    end
  end

  describe "flush/0" do
    test "removes all cache entries" do
      domain = "flush-test-#{System.unique_integer()}.test"
      Cache.put(domain, "A", <<1>>, "8.8.8.8:53")
      assert {:hit, _, _} = Cache.lookup(domain, "A")

      Cache.flush()
      assert :miss = Cache.lookup(domain, "A")
    end
  end

  describe "stats/0" do
    test "returns map with total, active, expired, ttl keys" do
      stats = Cache.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :total)
      assert Map.has_key?(stats, :active)
      assert Map.has_key?(stats, :expired)
      assert Map.has_key?(stats, :ttl)
    end

    test "counts active entries correctly" do
      Cache.flush()
      domain = "stats-test-#{System.unique_integer()}.test"
      Cache.put(domain, "A", <<1>>, "8.8.8.8:53")

      stats = Cache.stats()
      assert stats.active >= 1
    end
  end

  describe "parse_upstream/1" do
    test "parses ip:port format" do
      assert {:ok, {{8, 8, 8, 8}, 53}} = Cache.parse_upstream("8.8.8.8:53")
    end

    test "parses ip-only format with default port 53" do
      assert {:ok, {{1, 1, 1, 1}, 53}} = Cache.parse_upstream("1.1.1.1")
    end

    test "parses ip with non-standard port" do
      assert {:ok, {{9, 9, 9, 9}, 5353}} = Cache.parse_upstream("9.9.9.9:5353")
    end

    test "trims whitespace" do
      assert {:ok, {{8, 8, 8, 8}, 53}} = Cache.parse_upstream("  8.8.8.8:53  ")
    end

    test "returns error for invalid IP" do
      assert {:error, :invalid} = Cache.parse_upstream("999.999.999.999:53")
    end

    test "returns error for garbage input" do
      assert {:error, :invalid} = Cache.parse_upstream("not-an-ip")
    end

    test "returns error for empty string" do
      assert {:error, :invalid} = Cache.parse_upstream("")
    end

    test "returns error for multiple colons" do
      assert {:error, :invalid} = Cache.parse_upstream("1:2:3:4")
    end
  end

  describe "format_upstream/1" do
    test "formats ip tuple and port to string" do
      assert Cache.format_upstream({{8, 8, 8, 8}, 53}) == "8.8.8.8:53"
    end

    test "formats non-standard port" do
      assert Cache.format_upstream({{1, 1, 1, 1}, 5353}) == "1.1.1.1:5353"
    end
  end

  describe "get_upstreams/0" do
    test "returns a list of upstream tuples" do
      upstreams = Cache.get_upstreams()
      assert is_list(upstreams)
      assert length(upstreams) >= 1

      Enum.each(upstreams, fn {ip, port} ->
        assert is_tuple(ip)
        assert is_integer(port)
      end)
    end
  end

  describe "set_upstreams/1" do
    test "updates the upstream list" do
      original = Cache.get_upstreams()

      new_upstreams = [{{9, 9, 9, 9}, 53}]
      Cache.set_upstreams(new_upstreams)
      assert Cache.get_upstreams() == new_upstreams

      # Restore
      Cache.set_upstreams(original)
    end
  end

  describe "set_preset/1" do
    test "sets known preset upstreams" do
      original = Cache.get_upstreams()

      assert :ok = Cache.set_preset("cloudflare")
      upstreams = Cache.get_upstreams()
      assert {{1, 1, 1, 1}, 53} in upstreams
      assert {{1, 0, 0, 1}, 53} in upstreams

      Cache.set_upstreams(original)
    end

    test "returns error for unknown preset" do
      assert {:error, :unknown_preset} = Cache.set_preset("nonexistent")
    end
  end

  describe "presets/0" do
    test "returns a map of preset names to upstream lists" do
      presets = Cache.presets()
      assert is_map(presets)
      assert Map.has_key?(presets, "google")
      assert Map.has_key?(presets, "cloudflare")
      assert Map.has_key?(presets, "quad9")
      assert Map.has_key?(presets, "opendns")
    end
  end
end
