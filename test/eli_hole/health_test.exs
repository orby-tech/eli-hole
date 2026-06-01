defmodule EliHole.HealthTest do
  use EliHole.DataCase, async: false

  alias EliHole.Health

  describe "check/0" do
    test "reports :ok with every core check up when the app is running" do
      %{status: status, checks: checks} = Health.check()

      assert status == :ok
      assert checks.database == :ok
      assert checks.dns_server == :ok
      assert checks.cache == :ok
      assert checks.query_log == :ok
    end
  end

  describe "summarize/1" do
    test ":ok only when every check passed" do
      assert %{status: :ok} = Health.summarize(%{database: :ok, dns_server: :ok})
    end

    test ":degraded when any single check is down" do
      assert %{status: :degraded, checks: %{cache: :down}} =
               Health.summarize(%{database: :ok, dns_server: :ok, cache: :down})
    end
  end
end
