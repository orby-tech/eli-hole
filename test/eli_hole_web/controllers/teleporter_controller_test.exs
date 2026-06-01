defmodule EliHoleWeb.TeleporterControllerTest do
  use EliHoleWeb.ConnCase, async: false

  alias EliHole.DNS.BlocklistEntry

  describe "GET /admin/teleporter/export (unauthenticated)" do
    test "redirects to /login when setup is complete but no session", %{conn: conn} do
      # An admin must exist so RequireAuth treats setup as complete; otherwise it
      # redirects to /setup instead of /login.
      {:ok, _admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "admin_#{System.unique_integer([:positive])}",
          "password" => "supersecret123"
        })

      conn = get(conn, ~p"/admin/teleporter/export")
      assert redirected_to(conn) == ~p"/login"
    end

    test "does not return the export body when unauthenticated", %{conn: conn} do
      {:ok, _admin} =
        EliHole.Accounts.create_admin(%{
          "username" => "admin_#{System.unique_integer([:positive])}",
          "password" => "supersecret123"
        })

      conn = get(conn, ~p"/admin/teleporter/export")

      assert conn.halted
      assert conn.status == 302
      refute get_resp_header(conn, "content-disposition") |> Enum.any?(&(&1 =~ "attachment"))
    end
  end

  describe "GET /admin/teleporter/export (authenticated)" do
    setup :register_and_log_in_admin

    test "returns 200 with gzip content-type and attachment disposition", %{conn: conn} do
      conn = get(conn, ~p"/admin/teleporter/export")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/gzip"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ~r/filename="elihole-teleporter_.*\.tar\.gz"/

      assert is_binary(conn.resp_body)
      assert byte_size(conn.resp_body) > 0
    end

    test "body is a valid tar.gz containing the export files", %{conn: conn} do
      %BlocklistEntry{}
      |> BlocklistEntry.changeset(%{"domain" => "blocked.example.com", "type" => "exact"})
      |> EliHole.Repo.insert!()

      conn = get(conn, ~p"/admin/teleporter/export")

      assert {:ok, file_list} =
               :erl_tar.extract({:binary, conn.resp_body}, [:memory, :compressed])

      files = Map.new(file_list, fn {name, content} -> {List.to_string(name), content} end)

      assert Map.has_key?(files, "blocklist_exact.json")

      assert [%{"domain" => "blocked.example.com"}] =
               Jason.decode!(files["blocklist_exact.json"])
    end

    test "exported archive contains all eight config files", %{conn: conn} do
      conn = get(conn, ~p"/admin/teleporter/export")

      assert {:ok, file_list} =
               :erl_tar.extract({:binary, conn.resp_body}, [:memory, :compressed])

      names = Enum.map(file_list, fn {name, _} -> List.to_string(name) end)

      for expected <- ~w(blocklist_exact.json blocklist_wildcard.json blocklist_regex.json
                         whitelist_exact.json whitelist_wildcard.json whitelist_regex.json
                         providers.json local_dns.json) do
        assert expected in names, "missing #{expected} in export"
      end
    end
  end
end
