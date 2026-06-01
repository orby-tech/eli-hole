defmodule EliHole.DNSSEC.CanonicalTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.{Canonical, RR}
  alias EliHole.DNSSEC.RR.RRSIG
  alias EliHole.DNSSEC.Wire
  alias EliHole.DNSSECFixtures, as: F

  defp rr(opts) do
    %Wire.RR{
      name: Keyword.fetch!(opts, :name),
      type: Keyword.fetch!(opts, :type),
      class: Keyword.get(opts, :class, 1),
      ttl: Keyword.get(opts, :ttl, 3600),
      rdata: Keyword.fetch!(opts, :rdata)
    }
  end

  describe "name_wire/1 (RFC 4034 §6.1 canonical name form)" do
    test "down-cases labels, length-prefixes, root-terminates" do
      assert Canonical.name_wire(["Example", "COM"]) ==
               <<7>> <> "example" <> <<3>> <> "com" <> <<0>>
    end

    test "the empty label list is just the root terminator" do
      assert Canonical.name_wire([]) == <<0>>
    end

    test "down-casing is case-insensitive: mixed case collapses to one wire form" do
      assert Canonical.name_wire(["WwW", "Example", "Org"]) ==
               Canonical.name_wire(["www", "example", "org"])
    end

    test "single label is length-prefixed and terminated" do
      assert Canonical.name_wire(["a"]) == <<1, ?a, 0>>
    end
  end

  describe "canonical_rdata/2 — types without embedded names pass through unchanged" do
    test "A record (type 1) is identity" do
      rdata = <<192, 0, 2, 1>>
      assert Canonical.canonical_rdata(1, rdata) == rdata
    end

    test "AAAA (28), DNSKEY (48), DS (43), TXT (16) are identity" do
      for type <- [28, 48, 43, 16] do
        rdata = :crypto.strong_rand_bytes(20)
        assert Canonical.canonical_rdata(type, rdata) == rdata
      end
    end

    test "NSEC (47) is intentionally identity — next-name is NOT down-cased" do
      # RFC 6840 §5.1 removed NSEC from the down-case list.
      next = <<3>> <> "WWW" <> <<7>> <> "EXAMPLE" <> <<0>>
      bitmap = <<0, 1, 0>>
      assert Canonical.canonical_rdata(47, next <> bitmap) == next <> bitmap
    end
  end

  describe "canonical_rdata/2 — embedded names are down-cased (RFC 6840 §5.1 list)" do
    test "NS (2) down-cases the single name" do
      mixed = <<2>> <> "NS" <> <<7>> <> "Example" <> <<0>>
      lower = <<2>> <> "ns" <> <<7>> <> "example" <> <<0>>
      assert Canonical.canonical_rdata(2, mixed) == lower
    end

    test "CNAME (5), PTR (12), DNAME (39) down-case the single name" do
      for type <- [5, 12, 39] do
        mixed = <<4>> <> "MaIl" <> <<3>> <> "CoM" <> <<0>>
        lower = <<4>> <> "mail" <> <<3>> <> "com" <> <<0>>
        assert Canonical.canonical_rdata(type, mixed) == lower
      end
    end

    test "MX (15) keeps the 16-bit preference and down-cases the exchange name" do
      mixed = <<0, 10>> <> <<4>> <> "MAIL" <> <<7>> <> "Example" <> <<0>>
      lower = <<0, 10>> <> <<4>> <> "mail" <> <<7>> <> "example" <> <<0>>
      assert Canonical.canonical_rdata(15, mixed) == lower
    end

    test "SOA (6) down-cases both MNAME and RNAME but preserves trailing fixed fields" do
      mname = <<3>> <> "NS1" <> <<7>> <> "Example" <> <<0>>
      rname = <<5>> <> "Admin" <> <<7>> <> "Example" <> <<0>>
      # serial, refresh, retry, expire, minimum (5x 32-bit)
      fixed = <<1::32, 2::32, 3::32, 4::32, 5::32>>

      lower_m = <<3>> <> "ns1" <> <<7>> <> "example" <> <<0>>
      lower_r = <<5>> <> "admin" <> <<7>> <> "example" <> <<0>>

      assert Canonical.canonical_rdata(6, mname <> rname <> fixed) ==
               lower_m <> lower_r <> fixed
    end
  end

  describe "signing_input/2 — RRSIG RDATA prefix (RFC 4034 §3.1.8.1)" do
    defp base_rrsig(opts) do
      %RRSIG{
        type_covered: Keyword.get(opts, :type_covered, 1),
        algorithm: Keyword.get(opts, :algorithm, 13),
        labels: Keyword.get(opts, :labels, 2),
        original_ttl: Keyword.get(opts, :original_ttl, 3600),
        expiration: Keyword.get(opts, :expiration, 0),
        inception: Keyword.get(opts, :inception, 0),
        key_tag: Keyword.get(opts, :key_tag, 12_345),
        signer: Keyword.get(opts, :signer, ["example", "com"]),
        signature: Keyword.get(opts, :signature, <<>>)
      }
    end

    test "prefix packs the RRSIG fixed fields followed by the down-cased signer name" do
      rrsig = base_rrsig(signer: ["Example", "COM"])
      single = [rr(name: ["example", "com"], type: 1, rdata: <<192, 0, 2, 1>>)]

      input = Canonical.signing_input(rrsig, single)

      expected_prefix =
        <<1::16, 13::8, 2::8, 3600::32, 0::32, 0::32, 12_345::16>> <>
          <<7>> <> "example" <> <<3>> <> "com" <> <<0>>

      assert :binary.part(input, 0, byte_size(expected_prefix)) == expected_prefix
    end

    test "the signature field is excluded from the signing input" do
      rrsig = base_rrsig(signature: :crypto.strong_rand_bytes(64))
      single = [rr(name: ["example", "com"], type: 1, rdata: <<192, 0, 2, 1>>)]

      with_sig = Canonical.signing_input(rrsig, single)
      without_sig = Canonical.signing_input(%{rrsig | signature: <<>>}, single)

      assert with_sig == without_sig
    end

    test "uses the RRSIG Original TTL, not the packet RR TTL" do
      rrsig = base_rrsig(original_ttl: 60)

      packet_ttl_rr = [
        rr(name: ["example", "com"], type: 1, ttl: 999_999, rdata: <<192, 0, 2, 1>>)
      ]

      input = Canonical.signing_input(rrsig, packet_ttl_rr)

      # The serialized RR carries original_ttl (60), so 999_999 must not appear as a 32-bit TTL.
      assert :binary.match(input, <<60::32>>) != :nomatch
      refute :binary.match(input, <<999_999::32>>) != :nomatch
    end

    test "each RR is serialized as owner|type|class|ttl|rdlen|rdata" do
      # owner has exactly `labels` (2) labels → no wildcard reconstruction.
      rrsig = base_rrsig(original_ttl: 300, type_covered: 1, labels: 2)
      rdata = <<10, 0, 0, 1>>
      single = [rr(name: ["example", "com"], type: 1, class: 1, rdata: rdata)]

      input = Canonical.signing_input(rrsig, single)

      record =
        Canonical.name_wire(["example", "com"]) <>
          <<1::16, 1::16, 300::32, byte_size(rdata)::16>> <> rdata

      assert :binary.match(input, record) != :nomatch
    end
  end

  describe "signing_input/2 — RRset sorting (RFC 4034 §6.3)" do
    test "RRs are emitted sorted by canonical RDATA regardless of input order" do
      rrsig = %RRSIG{
        type_covered: 1,
        algorithm: 13,
        labels: 2,
        original_ttl: 300,
        expiration: 0,
        inception: 0,
        key_tag: 1,
        signer: ["example", "com"],
        signature: <<>>
      }

      low = rr(name: ["example", "com"], type: 1, rdata: <<10, 0, 0, 1>>)
      high = rr(name: ["example", "com"], type: 1, rdata: <<10, 0, 0, 2>>)

      sorted = Canonical.signing_input(rrsig, [low, high])
      reversed = Canonical.signing_input(rrsig, [high, low])

      assert sorted == reversed
    end

    test "shorter RDATA sorts before a longer one that shares its prefix (octet order)" do
      # RFC 4034 §6.3: 'absence of an octet sorts before a zero octet'.
      rrsig = %RRSIG{
        type_covered: 16,
        algorithm: 13,
        labels: 2,
        original_ttl: 300,
        expiration: 0,
        inception: 0,
        key_tag: 1,
        signer: ["example", "com"],
        signature: <<>>
      }

      shorter = rr(name: ["example", "com"], type: 16, rdata: <<1, ?a>>)
      longer = rr(name: ["example", "com"], type: 16, rdata: <<1, ?a, 0>>)

      input = Canonical.signing_input(rrsig, [longer, shorter])

      rec_short =
        Canonical.name_wire(["example", "com"]) <>
          <<16::16, 1::16, 300::32, 2::16>> <> <<1, ?a>>

      rec_long =
        Canonical.name_wire(["example", "com"]) <>
          <<16::16, 1::16, 300::32, 3::16>> <> <<1, ?a, 0>>

      pos_short = :binary.match(input, rec_short) |> elem(0)
      pos_long = :binary.match(input, rec_long) |> elem(0)
      assert pos_short < pos_long
    end

    test "sort is on canonical (down-cased) RDATA, not raw RDATA — NS names compared lower-cased" do
      rrsig = %RRSIG{
        type_covered: 2,
        algorithm: 13,
        labels: 2,
        original_ttl: 300,
        expiration: 0,
        inception: 0,
        key_tag: 1,
        signer: ["example", "com"],
        signature: <<>>
      }

      # Uppercase "A..." would sort before lowercase "b..." by raw bytes, but after
      # down-casing "a" (0x61) < "b" (0x62) — same as lowercase order. We verify that
      # the upper-case and lower-case forms produce identical signing input.
      upper = [
        rr(name: ["example", "com"], type: 2, rdata: <<1>> <> "B" <> <<0>>),
        rr(name: ["example", "com"], type: 2, rdata: <<1>> <> "A" <> <<0>>)
      ]

      lower = [
        rr(name: ["example", "com"], type: 2, rdata: <<1>> <> "b" <> <<0>>),
        rr(name: ["example", "com"], type: 2, rdata: <<1>> <> "a" <> <<0>>)
      ]

      assert Canonical.signing_input(rrsig, upper) == Canonical.signing_input(rrsig, lower)
    end
  end

  describe "signing_input/2 — wildcard owner reconstruction (RFC 4035 §5.3.2)" do
    test "labels < owner-label-count rebuilds owner as *.<rightmost labels>" do
      rrsig = %RRSIG{
        type_covered: 1,
        algorithm: 15,
        labels: 2,
        original_ttl: 60,
        expiration: 0,
        inception: 0,
        key_tag: 0,
        signer: ["example", "com"],
        signature: <<>>
      }

      single = [rr(name: ["sub", "example", "com"], type: 1, ttl: 60, rdata: <<5, 6, 7, 8>>)]
      input = Canonical.signing_input(rrsig, single)

      # The wildcard label appears, the queried-only label "sub" does not.
      assert :binary.match(input, <<1, ?*>>) != :nomatch
      assert :binary.match(input, "sub") == :nomatch

      # The reconstructed owner is exactly *.example.com
      assert :binary.match(input, Canonical.name_wire(["*", "example", "com"])) != :nomatch
    end

    test "labels == owner-label-count leaves the owner untouched (no wildcard)" do
      rrsig = %RRSIG{
        type_covered: 1,
        algorithm: 15,
        labels: 2,
        original_ttl: 60,
        expiration: 0,
        inception: 0,
        key_tag: 0,
        signer: ["example", "com"],
        signature: <<>>
      }

      single = [rr(name: ["example", "com"], type: 1, ttl: 60, rdata: <<5, 6, 7, 8>>)]
      input = Canonical.signing_input(rrsig, single)

      assert :binary.match(input, <<1, ?*>>) == :nomatch
      assert :binary.match(input, Canonical.name_wire(["example", "com"])) != :nomatch
    end

    test "wildcard reconstruction takes only the rightmost `labels` labels" do
      rrsig = %RRSIG{
        type_covered: 1,
        algorithm: 15,
        labels: 1,
        original_ttl: 60,
        expiration: 0,
        inception: 0,
        key_tag: 0,
        signer: ["com"],
        signature: <<>>
      }

      single = [rr(name: ["a", "b", "com"], type: 1, ttl: 60, rdata: <<1, 1, 1, 1>>)]
      input = Canonical.signing_input(rrsig, single)

      assert :binary.match(input, Canonical.name_wire(["*", "com"])) != :nomatch
      assert :binary.match(input, "a") == :nomatch
      assert :binary.match(input, "b") == :nomatch
    end
  end

  describe "integration with real captured RRsets" do
    test "signing input over the nlnetlabs.nl A RRset is deterministic and byte-stable" do
      {:ok, msg} = Wire.parse(F.packet(:nlnetlabs_a))

      rrsig =
        msg
        |> Wire.records_of_type(46)
        |> Enum.map(&RR.parse_rrsig(&1.rdata))
        |> Enum.find(&(&1.type_covered == 1))

      rrset = Wire.records_of_type(msg, 1)

      input1 = Canonical.signing_input(rrsig, rrset)
      input2 = Canonical.signing_input(rrsig, Enum.reverse(rrset))

      assert is_binary(input1)
      assert byte_size(input1) > 0
      assert input1 == input2
    end

    test "root DNSKEY RRset signing input begins with the RRSIG prefix and root signer" do
      {:ok, msg} = Wire.parse(F.packet(:root_dnskey))

      rrsig =
        msg
        |> Wire.records_of_type(46)
        |> Enum.map(&RR.parse_rrsig(&1.rdata))
        |> Enum.find(&(&1.type_covered == 48))

      rrset = Wire.records_of_type(msg, 48)
      input = Canonical.signing_input(rrsig, rrset)

      # signer for the root is "." → just the root terminator after the fixed fields.
      prefix =
        <<rrsig.type_covered::16, rrsig.algorithm::8, rrsig.labels::8, rrsig.original_ttl::32,
          rrsig.expiration::32, rrsig.inception::32, rrsig.key_tag::16, 0>>

      assert :binary.part(input, 0, byte_size(prefix)) == prefix
    end
  end
end
