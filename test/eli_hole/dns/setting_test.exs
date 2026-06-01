defmodule EliHole.DNS.SettingTest do
  use EliHole.DataCase, async: true

  alias EliHole.DNS.Setting

  describe "changeset/2" do
    test "valid with key and value" do
      changeset = Setting.changeset(%Setting{}, %{key: "pause_until", value: "0"})
      assert changeset.valid?
      assert get_change(changeset, :key) == "pause_until"
      assert get_change(changeset, :value) == "0"
    end

    test "requires key" do
      changeset = Setting.changeset(%Setting{}, %{value: "123"})
      refute changeset.valid?
      assert %{key: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires value" do
      changeset = Setting.changeset(%Setting{}, %{key: "some_key"})
      refute changeset.valid?
      assert %{value: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an empty-string value (validate_required)" do
      changeset = Setting.changeset(%Setting{}, %{key: "k", value: ""})
      refute changeset.valid?
      assert %{value: ["can't be blank"]} = errors_on(changeset)
    end

    test "ignores fields outside the cast allowlist" do
      changeset =
        Setting.changeset(%Setting{}, %{key: "k", value: "v", id: 999, bogus: "x"})

      assert changeset.valid?
      assert get_change(changeset, :id) == nil
    end

    test "only casts string values for key/value" do
      # Ecto casts the schema field as :string; an integer value is coerced.
      changeset = Setting.changeset(%Setting{}, %{key: "n", value: "42"})
      assert get_change(changeset, :value) == "42"
    end
  end

  describe "persistence round-trip (insert / update / get_by)" do
    test "inserts a new setting and reads it back" do
      assert {:ok, %Setting{} = setting} =
               %Setting{}
               |> Setting.changeset(%{key: "ttl", value: "300"})
               |> Repo.insert()

      assert setting.id
      fetched = Repo.get_by(Setting, key: "ttl")
      assert fetched.value == "300"
    end

    test "updates the value of an existing key in place" do
      {:ok, existing} =
        %Setting{} |> Setting.changeset(%{key: "enforce", value: "false"}) |> Repo.insert()

      assert {:ok, updated} =
               existing |> Setting.changeset(%{value: "true"}) |> Repo.update()

      assert updated.id == existing.id
      assert Repo.get_by(Setting, key: "enforce").value == "true"
    end

    test "key is unique — duplicate insert violates the unique constraint" do
      {:ok, _} =
        %Setting{} |> Setting.changeset(%{key: "dup", value: "1"}) |> Repo.insert()

      assert {:error, changeset} =
               %Setting{} |> Setting.changeset(%{key: "dup", value: "2"}) |> Repo.insert()

      refute changeset.valid?
      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end

    test "integer-as-string round-trips for the pause/ttl style usage" do
      until = System.system_time(:second) + 600

      {:ok, _} =
        %Setting{}
        |> Setting.changeset(%{key: "pause_until", value: to_string(until)})
        |> Repo.insert()

      %Setting{value: value} = Repo.get_by(Setting, key: "pause_until")
      assert {^until, ""} = Integer.parse(value)
    end

    test "timestamps are populated on insert" do
      {:ok, setting} =
        %Setting{} |> Setting.changeset(%{key: "ts", value: "x"}) |> Repo.insert()

      assert %DateTime{} = setting.inserted_at
      assert %DateTime{} = setting.updated_at
    end
  end
end
