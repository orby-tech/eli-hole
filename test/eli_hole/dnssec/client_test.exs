defmodule EliHole.DNSSEC.ClientTest do
  # Touches process/ETS/global Application env (dns_upstreams) — must not run async.
  use ExUnit.Case, async: false

  alias EliHole.DNS.Cache
  alias EliHole.DNSSEC.Client
  alias EliHole.DNSSEC.Wire
  alias EliHole.DNSSECFixtures, as: F

  @table :dnssec_records
  @settings_table :dns_cache_settings

  setup do
    # Cache and Client are started by the application supervisor; reuse them rather
    # than starting duplicates. Force the upstream list empty so any cache MISS fails
    # fast with :all_upstreams_failed and NEVER touches the real network:
    #   * delete any :upstreams entry in the Cache settings table (set during init), and
    #   * point the Application-env fallback at an empty list.
    ensure_started(Cache)
    ensure_started(Client)

    prev_settings =
      case :ets.lookup(@settings_table, :upstreams) do
        [{:upstreams, val}] -> {:set, val}
        _ -> :unset
      end

    :ets.delete(@settings_table, :upstreams)

    prev_env = Application.get_env(:eli_hole, :dns_upstreams)
    Application.put_env(:eli_hole, :dns_upstreams, [])

    # Start each test from an empty DNSSEC cache.
    :ets.delete_all_objects(@table)

    on_exit(fn ->
      Application.put_env(:eli_hole, :dns_upstreams, prev_env)

      case prev_settings do
        {:set, val} -> :ets.insert(@settings_table, {:upstreams, val})
        :unset -> :ok
      end
    end)

    :ok
  end

  defp ensure_started(mod) do
    case Process.whereis(mod) do
      nil -> start_supervised!(mod)
      pid -> pid
    end
  end

  # Build a parsed %Wire.Message{} from a captured packet, and the {name, type} the
  # Client would key its cache on for that query.
  defp parsed(packet) do
    {:ok, msg} = Wire.parse(packet)
    msg
  end

  defp seed_cache(key, msg, ttl_seconds) do
    expires_at = System.monotonic_time(:second) + ttl_seconds
    true = :ets.insert(@table, {key, msg, expires_at})
  end

  describe "GenServer lifecycle" do
    test "init creates the named ETS cache table" do
      assert :ets.info(@table) != :undefined
      assert :ets.info(@table, :name) == @table
    end

    test "process is alive and registered under its module name" do
      assert is_pid(Process.whereis(Client))
      assert %{} = :sys.get_state(Client)
    end
  end

  describe "query/2 cache hit (no network)" do
    test "returns the cached message when the entry is unexpired" do
      msg = parsed(F.packet(:cloudflare_dnskey))
      seed_cache({"cloudflare.com", 48}, msg, 300)

      assert {:ok, ^msg} = Client.query("cloudflare.com", 48)
    end

    test "cache is keyed by {name, type} — different type misses the seeded entry" do
      msg = parsed(F.packet(:cloudflare_dnskey))
      seed_cache({"cloudflare.com", 48}, msg, 300)

      # type 48 hits, type 43 misses → falls through to network → no upstreams.
      assert {:ok, ^msg} = Client.query("cloudflare.com", 48)
      assert {:error, :all_upstreams_failed} = Client.query("cloudflare.com", 43)
    end

    test "cache is keyed by name — a different name misses" do
      msg = parsed(F.packet(:cloudflare_dnskey))
      seed_cache({"cloudflare.com", 48}, msg, 300)

      assert {:error, :all_upstreams_failed} = Client.query("example.com", 48)
    end

    test "an expired entry is treated as a miss" do
      msg = parsed(F.packet(:cloudflare_dnskey))
      # Negative TTL → expires_at is already in the past.
      seed_cache({"cloudflare.com", 48}, msg, -1)

      assert {:error, :all_upstreams_failed} = Client.query("cloudflare.com", 48)
    end

    test "root (\".\") DNSKEY can be cached and served" do
      msg = parsed(F.packet(:root_dnskey))
      seed_cache({".", 48}, msg, 300)

      assert {:ok, ^msg} = Client.query(".", 48)
    end
  end

  describe "query/2 cache miss (no network)" do
    test "empty upstream list yields :all_upstreams_failed without touching the network" do
      assert {:error, :all_upstreams_failed} = Client.query("nlnetlabs.nl", 48)
    end

    test "a failed query is NOT inserted into the cache" do
      assert {:error, :all_upstreams_failed} = Client.query("nlnetlabs.nl", 48)
      assert :ets.lookup(@table, {"nlnetlabs.nl", 48}) == []
    end
  end

  describe "input contracts" do
    test "query/2 requires a binary name and integer type" do
      assert_raise FunctionClauseError, fn -> Client.query(:not_binary, 48) end
      assert_raise FunctionClauseError, fn -> Client.query("example.com", "48") end
    end
  end
end
