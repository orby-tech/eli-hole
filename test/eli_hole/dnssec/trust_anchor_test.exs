defmodule EliHole.DNSSEC.TrustAnchorTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.RR.DS
  alias EliHole.DNSSEC.TrustAnchor

  describe "root_ds/0" do
    test "returns two DS structs (KSK-2017 and KSK-2024 both pinned)" do
      anchors = TrustAnchor.root_ds()
      assert length(anchors) == 2
      assert Enum.all?(anchors, &match?(%DS{}, &1))
    end

    test "includes the KSK-2017 anchor (key tag 20326)" do
      anchors = TrustAnchor.root_ds()
      ksk2017 = Enum.find(anchors, &(&1.key_tag == 20326))

      assert ksk2017
      assert ksk2017.algorithm == 8
      assert ksk2017.digest_type == 2
    end

    test "includes the KSK-2024 anchor (key tag 38696)" do
      anchors = TrustAnchor.root_ds()
      ksk2024 = Enum.find(anchors, &(&1.key_tag == 38696))

      assert ksk2024
      assert ksk2024.algorithm == 8
      assert ksk2024.digest_type == 2
    end

    test "every anchor uses RSASHA256 (alg 8) and SHA-256 digest (type 2)" do
      for ds <- TrustAnchor.root_ds() do
        assert ds.algorithm == 8
        assert ds.digest_type == 2
      end
    end

    test "digests are 32 raw bytes (SHA-256 length)" do
      for ds <- TrustAnchor.root_ds() do
        assert byte_size(ds.digest) == 32
      end
    end

    test "KSK-2017 digest matches the IANA-published value" do
      ds = Enum.find(TrustAnchor.root_ds(), &(&1.key_tag == 20326))

      assert Base.encode16(ds.digest) ==
               "E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D"
    end

    test "KSK-2024 digest matches the IANA-published value" do
      ds = Enum.find(TrustAnchor.root_ds(), &(&1.key_tag == 38696))

      assert Base.encode16(ds.digest) ==
               "683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16"
    end

    test "key tags are unique" do
      tags = TrustAnchor.root_ds() |> Enum.map(& &1.key_tag)
      assert tags == Enum.uniq(tags)
    end
  end

  describe "root_ds/1 (filter by key tag)" do
    test "returns the single matching anchor for 20326" do
      assert [%DS{key_tag: 20326}] = TrustAnchor.root_ds(20326)
    end

    test "returns the single matching anchor for 38696" do
      assert [%DS{key_tag: 38696}] = TrustAnchor.root_ds(38696)
    end

    test "returns an empty list for an unknown key tag" do
      assert TrustAnchor.root_ds(1) == []
      assert TrustAnchor.root_ds(0) == []
    end

    test "filtered result is a subset of all anchors" do
      all = TrustAnchor.root_ds()
      filtered = TrustAnchor.root_ds(20326)
      assert Enum.all?(filtered, &(&1 in all))
    end
  end
end
