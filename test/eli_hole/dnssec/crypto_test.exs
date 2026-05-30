defmodule EliHole.DNSSEC.CryptoTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.{Canonical, Crypto, RR, TrustAnchor, Wire}
  alias EliHole.DNSSECFixtures, as: F

  # Pull the DNSKEY (matching the RRSIG key tag), the RRSIG covering `type`, and the
  # covered RRset out of one or two captured packets.
  defp setup_verify(rrset_packet, type, key_packet) do
    {:ok, rmsg} = Wire.parse(rrset_packet)

    rrsig =
      rmsg
      |> Wire.records_of_type(46)
      |> Enum.map(&RR.parse_rrsig(&1.rdata))
      |> Enum.find(&(&1.type_covered == type))

    rrset = Wire.records_of_type(rmsg, type)

    {:ok, kmsg} = Wire.parse(key_packet)

    dnskey =
      kmsg
      |> Wire.records_of_type(48)
      |> Enum.map(&RR.parse_dnskey(&1.rdata))
      |> Enum.find(&(RR.key_tag(&1) == rrsig.key_tag))

    {rrsig, rrset, dnskey}
  end

  describe "verify_rrsig/3 — RSA (alg 8)" do
    test "valid RSASHA256 signature over nlnetlabs.nl A RRset verifies" do
      {rrsig, rrset, key} = setup_verify(F.packet(:nlnetlabs_a), 1, F.packet(:nlnetlabs_dnskey))
      assert key.algorithm == 8
      assert Crypto.verify_rrsig(rrsig, rrset, key)
    end

    test "root DNSKEY self-signature (KSK over the DNSKEY RRset) verifies" do
      {rrsig, rrset, key} = setup_verify(F.packet(:root_dnskey), 48, F.packet(:root_dnskey))
      assert Crypto.verify_rrsig(rrsig, rrset, key)
    end

    test "a one-byte mutation of the signature fails" do
      {rrsig, rrset, key} = setup_verify(F.packet(:nlnetlabs_a), 1, F.packet(:nlnetlabs_dnskey))
      <<first, rest::binary>> = rrsig.signature
      bad = %{rrsig | signature: <<Bitwise.bxor(first, 1), rest::binary>>}
      refute Crypto.verify_rrsig(bad, rrset, key)
    end

    test "a mutated RRset (flipped A address byte) fails" do
      {rrsig, rrset, key} = setup_verify(F.packet(:nlnetlabs_a), 1, F.packet(:nlnetlabs_dnskey))
      [rr | rest] = rrset
      <<b, tail::binary>> = rr.rdata
      bad_rrset = [%{rr | rdata: <<Bitwise.bxor(b, 1), tail::binary>>} | rest]
      refute Crypto.verify_rrsig(rrsig, bad_rrset, key)
    end
  end

  describe "verify_rrsig/3 — ECDSA (alg 13, raw r||s DER-wrapped)" do
    test "valid ECDSAP256SHA256 signature over www.cloudflare.com A RRset verifies" do
      {rrsig, rrset, key} =
        setup_verify(F.packet(:www_cloudflare_a), 1, F.packet(:cloudflare_dnskey))

      assert key.algorithm == 13
      assert Crypto.verify_rrsig(rrsig, rrset, key)
    end

    test "cloudflare.com DNSKEY self-signature verifies" do
      {rrsig, rrset, key} =
        setup_verify(F.packet(:cloudflare_dnskey), 48, F.packet(:cloudflare_dnskey))

      assert Crypto.verify_rrsig(rrsig, rrset, key)
    end

    test "wrong key (mismatched algorithm) returns false, never raises" do
      {rrsig, rrset, _key} =
        setup_verify(F.packet(:www_cloudflare_a), 1, F.packet(:cloudflare_dnskey))

      rsa_key =
        :nlnetlabs_dnskey
        |> F.packet()
        |> then(fn p ->
          {:ok, m} = Wire.parse(p)
          m |> Wire.records_of_type(48) |> List.first() |> Map.get(:rdata) |> RR.parse_dnskey()
        end)

      refute Crypto.verify_rrsig(rrsig, rrset, rsa_key)
    end
  end

  describe "verify_rrsig/3 — EdDSA (alg 15) crypto wiring" do
    # No public Ed25519-signed zone was reachable at capture time, so this exercises the
    # :eddsa / :none / :ed25519 dispatch against a locally generated key. It proves the
    # :crypto argument shape is correct; real-zone coverage lands with the validator (Loop 2).
    test "self-generated Ed25519 signature over a canonical input verifies, mutation fails" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      rrset = [
        %Wire.RR{name: ["example", "com"], type: 1, class: 1, ttl: 3600, rdata: <<1, 2, 3, 4>>}
      ]

      dnskey = %RR.DNSKEY{algorithm: 15, public_key: pub, rdata: <<0, 0, 0, 15>> <> pub}

      # key_tag must be fixed BEFORE computing the signing input — it is part of it.
      unsigned = %RR.RRSIG{
        type_covered: 1,
        algorithm: 15,
        labels: 2,
        original_ttl: 3600,
        expiration: 0,
        inception: 0,
        key_tag: RR.key_tag(dnskey.rdata),
        signer: ["example", "com"],
        signature: <<>>
      }

      data = Canonical.signing_input(unsigned, rrset)
      sig = :crypto.sign(:eddsa, :none, data, [priv, :ed25519])
      signed = %{unsigned | signature: sig}

      assert Crypto.verify_rrsig(signed, rrset, dnskey)

      <<f, rest::binary>> = sig
      bad = %{signed | signature: <<Bitwise.bxor(f, 1), rest::binary>>}
      refute Crypto.verify_rrsig(bad, rrset, dnskey)
    end
  end

  describe "wildcard signing input (RFC 4035 §5.3.2)" do
    test "owner is reconstructed as *.<rightmost labels> when RRSIG labels < owner labels" do
      # queried name has 3 labels; signed with labels=2 → canonical owner is *.example.com
      rrset = [
        %Wire.RR{
          name: ["sub", "example", "com"],
          type: 1,
          class: 1,
          ttl: 60,
          rdata: <<5, 6, 7, 8>>
        }
      ]

      rrsig = %RR.RRSIG{
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

      input = Canonical.signing_input(rrsig, rrset)
      # the wildcard label "*" (\x01*) must appear; the queried label "sub" must NOT
      assert :binary.match(input, <<1, ?*>>) != :nomatch
      assert :binary.match(input, "sub") == :nomatch
    end

    test "an Ed25519 RRSIG signed over the wildcard owner verifies for a longer queried name" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      dnskey = %RR.DNSKEY{algorithm: 15, public_key: pub, rdata: <<0, 0, 0, 15>> <> pub}

      rrset = [
        %Wire.RR{
          name: ["host", "wild", "example"],
          type: 1,
          class: 1,
          ttl: 300,
          rdata: <<9, 9, 9, 9>>
        }
      ]

      unsigned = %RR.RRSIG{
        type_covered: 1,
        algorithm: 15,
        labels: 2,
        original_ttl: 300,
        expiration: 0,
        inception: 0,
        key_tag: RR.key_tag(dnskey.rdata),
        signer: ["wild", "example"],
        signature: <<>>
      }

      sig =
        :crypto.sign(:eddsa, :none, Canonical.signing_input(unsigned, rrset), [priv, :ed25519])

      assert Crypto.verify_rrsig(%{unsigned | signature: sig}, rrset, dnskey)
    end
  end

  describe "verify_ds/3" do
    test "cloudflare.com DS matches the cloudflare KSK DNSKEY" do
      {:ok, dmsg} = Wire.parse(F.packet(:cloudflare_ds))
      ds = dmsg |> Wire.records_of_type(43) |> List.first() |> Map.get(:rdata) |> RR.parse_ds()

      {:ok, kmsg} = Wire.parse(F.packet(:cloudflare_dnskey))

      ksk =
        kmsg
        |> Wire.records_of_type(48)
        |> Enum.map(&RR.parse_dnskey(&1.rdata))
        |> Enum.find(&(RR.key_tag(&1) == ds.key_tag))

      assert ksk, "no DNSKEY matching DS key tag #{ds.key_tag}"
      assert Crypto.verify_ds(ds, ksk, ["cloudflare", "com"])
    end

    test "root KSK DNSKEY matches a hardcoded root trust anchor" do
      {:ok, kmsg} = Wire.parse(F.packet(:root_dnskey))
      keys = kmsg |> Wire.records_of_type(48) |> Enum.map(&RR.parse_dnskey(&1.rdata))

      anchor = List.first(TrustAnchor.root_ds())
      ksk = Enum.find(keys, &(RR.key_tag(&1) == anchor.key_tag))

      assert ksk, "root DNSKEY for anchor tag #{anchor.key_tag} not in fixture"
      assert Crypto.verify_ds(anchor, ksk, [])
    end

    test "DS digest mismatch fails" do
      {:ok, kmsg} = Wire.parse(F.packet(:cloudflare_dnskey))

      ksk =
        kmsg
        |> Wire.records_of_type(48)
        |> Enum.map(&RR.parse_dnskey(&1.rdata))
        |> Enum.find(&RR.sep?/1)

      tag = RR.key_tag(ksk)

      bad_ds = %RR.DS{
        key_tag: tag,
        algorithm: ksk.algorithm,
        digest_type: 2,
        digest: :crypto.strong_rand_bytes(32)
      }

      refute Crypto.verify_ds(bad_ds, ksk, ["cloudflare", "com"])
    end
  end
end
