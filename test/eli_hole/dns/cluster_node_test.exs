defmodule EliHole.DNS.ClusterNodeTest do
  use EliHole.DataCase, async: true

  alias EliHole.DNS.ClusterNode

  describe "changeset/2" do
    test "valid with required name, url, api_key" do
      cs =
        ClusterNode.changeset(%ClusterNode{}, %{
          name: "node-a",
          url: "https://example.com",
          api_key: "secret"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :name) == "node-a"
      assert Ecto.Changeset.get_field(cs, :url) == "https://example.com"
      assert Ecto.Changeset.get_field(cs, :api_key) == "secret"
    end

    test "defaults status to pending on a fresh struct" do
      assert %ClusterNode{}.status == "pending"
    end

    test "casts an explicit status and last_seen_at" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      cs =
        ClusterNode.changeset(%ClusterNode{}, %{
          name: "n",
          url: "http://x",
          api_key: "k",
          status: "online",
          last_seen_at: now
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "online"
      assert Ecto.Changeset.get_field(cs, :last_seen_at) == now
    end

    test "requires name" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{url: "http://x", api_key: "k"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "requires url" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{name: "n", api_key: "k"})
      refute cs.valid?
      assert %{url: ["can't be blank"]} = errors_on(cs)
    end

    test "requires api_key" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{name: "n", url: "http://x"})
      refute cs.valid?
      assert %{api_key: ["can't be blank"]} = errors_on(cs)
    end

    test "accepts http and https urls" do
      assert ClusterNode.changeset(%ClusterNode{}, %{name: "a", url: "http://x", api_key: "k"}).valid?

      assert ClusterNode.changeset(%ClusterNode{}, %{name: "b", url: "https://x", api_key: "k"}).valid?
    end

    test "rejects a url without an http(s) scheme" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{name: "n", url: "ftp://x", api_key: "k"})
      refute cs.valid?
      assert %{url: ["must be an HTTP(S) URL"]} = errors_on(cs)
    end

    test "rejects a bare host url" do
      cs = ClusterNode.changeset(%ClusterNode{}, %{name: "n", url: "example.com", api_key: "k"})
      refute cs.valid?
      assert %{url: ["must be an HTTP(S) URL"]} = errors_on(cs)
    end

    test "enforces unique name via constraint" do
      attrs = %{name: "dup-name", url: "http://one", api_key: "k"}
      assert {:ok, _} = %ClusterNode{} |> ClusterNode.changeset(attrs) |> Repo.insert()

      {:error, cs} =
        %ClusterNode{}
        |> ClusterNode.changeset(%{name: "dup-name", url: "http://two", api_key: "k"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "enforces unique url via constraint" do
      attrs = %{name: "n1", url: "http://dup-url", api_key: "k"}
      assert {:ok, _} = %ClusterNode{} |> ClusterNode.changeset(attrs) |> Repo.insert()

      {:error, cs} =
        %ClusterNode{}
        |> ClusterNode.changeset(%{name: "n2", url: "http://dup-url", api_key: "k"})
        |> Repo.insert()

      assert %{url: ["has already been taken"]} = errors_on(cs)
    end
  end
end
