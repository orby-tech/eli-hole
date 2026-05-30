defmodule EliHole.DNSSEC.ConfigTest do
  # Not async: Config is a singleton GenServer with global ETS state.
  use EliHole.DataCase, async: false

  alias EliHole.DNSSEC.Config

  setup do
    on_exit(fn -> Config.set_enforce(false) end)
    :ok
  end

  test "enforce defaults to false and round-trips through set_enforce/1" do
    assert Config.enforce?() == false

    assert :ok = Config.set_enforce(true)
    assert Config.enforce?() == true

    assert :ok = Config.set_enforce(false)
    assert Config.enforce?() == false
  end

  test "set_enforce/1 persists to dns_settings" do
    Config.set_enforce(true)
    assert EliHole.Repo.get_by(EliHole.DNS.Setting, key: "dnssec_enforce").value == "true"
  end

  test "set_enforce/1 broadcasts the change" do
    Phoenix.PubSub.subscribe(EliHole.PubSub, "dnssec:config")
    Config.set_enforce(true)
    assert_receive {:enforce_changed, true}
  end
end
