defmodule EliHoleWeb.DashboardLiveTest do
  use EliHoleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EliHole.DNS.PauseControl

  describe "authentication" do
    test "redirects to /login when not authenticated", %{conn: conn} do
      # An admin must exist so setup is complete; otherwise RequireAuth sends
      # an unauthed visitor to /setup instead of /login.
      {:ok, _admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "existing_admin",
          "password" => "supersecret123"
        })

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin")
    end
  end

  describe "mount and render" do
    setup :register_and_log_in_admin

    setup do
      # Ensure a clean, unpaused baseline regardless of prior tests, and restore
      # it on exit — PauseControl is a global GenServer the SQL sandbox can't
      # roll back, so a leaked pause would break blocklist/resolver tests.
      PauseControl.resume()
      _ = :sys.get_state(PauseControl)
      on_exit(fn -> PauseControl.resume() end)
      :ok
    end

    test "renders the dashboard heading and stat cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, "h1", "Dashboard")
      assert has_element?(view, "#period-today")
      assert has_element?(view, "#period-week")
      assert has_element?(view, "#period-month")
      assert has_element?(view, "#pause-control")
    end

    test "today period is active by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      # Active period renders a bare `aria-pressed` (true); inactive ones omit it.
      assert has_element?(view, "#period-today[aria-pressed]")
      assert has_element?(view, "#period-week:not([aria-pressed])")
    end
  end

  describe "period switching" do
    setup :register_and_log_in_admin

    test "set_period switches the active period", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      view |> element("#period-week") |> render_click()

      assert has_element?(view, "#period-week[aria-pressed]")
      assert has_element?(view, "#period-today:not([aria-pressed])")

      view |> element("#period-month") |> render_click()

      assert has_element?(view, "#period-month[aria-pressed]")
    end
  end

  describe "pause control" do
    setup :register_and_log_in_admin

    setup do
      PauseControl.resume()
      _ = :sys.get_state(PauseControl)
      :ok
    end

    test "shows pause buttons when blocking is active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, "#pause-1m")
      assert has_element?(view, "#pause-5m")
      assert has_element?(view, "#pause-15m")
      assert has_element?(view, "#pause-60m")
      refute has_element?(view, "#resume-blocking")
    end

    test "clicking a pause button pauses blocking and shows resume", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      view |> element("#pause-5m") |> render_click()

      assert has_element?(view, "#resume-blocking")
      refute has_element?(view, "#pause-5m")
      assert PauseControl.paused?()
    end

    test "resume re-enables blocking", %{conn: conn} do
      PauseControl.pause(5)
      _ = :sys.get_state(PauseControl)

      {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "#resume-blocking")

      view |> element("#resume-blocking") |> render_click()

      assert has_element?(view, "#pause-1m")
      refute has_element?(view, "#resume-blocking")
      refute PauseControl.paused?()
    end
  end
end
