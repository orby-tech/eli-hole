defmodule EliHoleWeb.SettingsLiveTest do
  use EliHoleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EliHole.DNS.{Cache, Providers, RateLimiter}
  alias EliHole.DNSSEC.Config, as: DnssecConfig

  setup do
    # Reset shared singletons to a known baseline so tests don't bleed state.
    # These are global GenServers with ETS caches that the SQL sandbox does NOT
    # roll back, so we must restore them on exit too — otherwise a limit/enabled
    # change here leaks into other files (e.g. RateLimiterTest).
    DnssecConfig.set_enforce(false)
    _ = :sys.get_state(DnssecConfig)
    RateLimiter.set_enabled(false)
    RateLimiter.set_limit(100)
    _ = :sys.get_state(RateLimiter)

    prev_ttl = Cache.get_ttl()
    prev_upstreams = Cache.get_upstreams()

    on_exit(fn ->
      DnssecConfig.set_enforce(false)
      RateLimiter.set_enabled(false)
      RateLimiter.set_limit(100)
      Cache.set_ttl(prev_ttl)
      Cache.set_upstreams(prev_upstreams)
    end)

    :ok
  end

  describe "authentication" do
    test "redirects to /login when not authenticated", %{conn: conn} do
      {:ok, _admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "existing_admin",
          "password" => "supersecret123"
        })

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/settings")
    end
  end

  describe "mount and render" do
    setup :register_and_log_in_admin

    test "renders the settings sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      assert has_element?(view, "h1", "Settings")
      assert has_element?(view, "input[phx-click='toggle_dnssec_enforce']")
      assert has_element?(view, "input[phx-click='toggle_rate_limit']")
      assert has_element?(view, "form[phx-submit='add_upstream']")
      assert has_element?(view, "form[phx-submit='set_ttl']")
      assert has_element?(view, "#teleporter-import-form")
    end

    test "renders configured providers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      # At least one provider preset toggle button is rendered.
      assert has_element?(view, "button[phx-click='toggle_preset']")
    end
  end

  describe "DNSSEC enforcement toggle" do
    setup :register_and_log_in_admin

    test "toggling flips the enforce config", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")
      refute DnssecConfig.enforce?()

      view |> element("input[phx-click='toggle_dnssec_enforce']") |> render_click()

      assert DnssecConfig.enforce?()
      assert has_element?(view, "input[phx-click='toggle_dnssec_enforce'][checked]")
    end
  end

  describe "rate limiting" do
    setup :register_and_log_in_admin

    test "toggling on reveals the limit form and enables the limiter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")
      refute has_element?(view, "form[phx-submit='set_rate_limit']")

      view |> element("input[phx-click='toggle_rate_limit']") |> render_click()

      assert RateLimiter.config().enabled
      assert has_element?(view, "form[phx-submit='set_rate_limit']")
    end

    test "submitting a valid limit applies it", %{conn: conn} do
      RateLimiter.set_enabled(true)
      _ = :sys.get_state(RateLimiter)

      {:ok, view, _html} = live(conn, "/admin/settings")

      view
      |> element("form[phx-submit='set_rate_limit']")
      |> render_submit(%{"limit" => "42"})

      assert RateLimiter.config().limit == 42
    end

    test "submitting an invalid limit flashes an error", %{conn: conn} do
      RateLimiter.set_enabled(true)
      _ = :sys.get_state(RateLimiter)

      {:ok, view, _html} = live(conn, "/admin/settings")

      html =
        view
        |> element("form[phx-submit='set_rate_limit']")
        |> render_submit(%{"limit" => "abc"})

      assert html =~ "positive integer"
    end
  end

  describe "cache TTL" do
    setup :register_and_log_in_admin

    test "applying a valid TTL updates the cache TTL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      view
      |> element("form[phx-submit='set_ttl']")
      |> render_submit(%{"ttl" => "1234"})

      assert Cache.stats().ttl == 1234
    end

    test "flush_cache button is present and clickable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      assert view
             |> element("button[phx-click='flush_cache']")
             |> render_click() =~ "Cache"
    end
  end

  describe "upstreams" do
    setup :register_and_log_in_admin

    test "adding a valid upstream creates a provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")
      before = length(Providers.list_all())

      view
      |> element("form[phx-submit='add_upstream']")
      |> render_submit(%{"upstream" => "9.9.9.9:5300"})

      providers = Providers.list_all()
      assert length(providers) == before + 1
      assert Enum.any?(providers, &(&1.ip == "9.9.9.9" and &1.port == 5300))
    end

    test "adding an invalid upstream flashes an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/settings")

      html =
        view
        |> element("form[phx-submit='add_upstream']")
        |> render_submit(%{"upstream" => "not-an-ip"})

      assert html =~ "Invalid format"
    end
  end
end
