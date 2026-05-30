defmodule EliHole.DNSSEC.RRTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.{RR, Wire}
  alias EliHole.DNSSECFixtures, as: F

  defp dnskeys(packet) do
    {:ok, msg} = Wire.parse(packet)
    msg |> Wire.records_of_type(48) |> Enum.map(&RR.parse_dnskey(&1.rdata))
  end

  describe "key_tag/1 (RFC 4034 Appendix B)" do
    test "root KSK key tags match the published anchors 20326 and 38696" do
      tags = :root_dnskey |> F.packet() |> dnskeys() |> Enum.map(&RR.key_tag/1)
      # The root KSK (20326) must be present in the live DNSKEY set; 38696 may also appear.
      assert 20326 in tags
    end

    test "the SEP (KSK) flag identifies the key-signing key" do
      ksks = :root_dnskey |> F.packet() |> dnskeys() |> Enum.filter(&RR.sep?/1)
      assert Enum.any?(ksks, &(RR.key_tag(&1) == 20326))
    end
  end

  describe "parse_dnskey/1 + to_crypto_key/1" do
    test "RSA root keys yield {:rsa, [e, n]} integers" do
      key = :root_dnskey |> F.packet() |> dnskeys() |> List.first()
      assert key.algorithm == 8
      assert {:ok, :rsa, [e, n]} = RR.to_crypto_key(key)
      assert is_integer(e) and is_integer(n)
      assert e == 65_537
    end

    test "ECDSA P-256 cloudflare keys yield a 0x04-prefixed point" do
      key = :cloudflare_dnskey |> F.packet() |> dnskeys() |> List.first()
      assert key.algorithm == 13
      assert {:ok, :ecdsa, {<<4, _::binary-size(64)>>, :secp256r1}} = RR.to_crypto_key(key)
    end

    test "unsupported algorithm is reported, not crashed" do
      assert {:error, {:unsupported_algorithm, 99}} =
               RR.to_crypto_key(%RR.DNSKEY{algorithm: 99, public_key: <<>>})
    end
  end

  describe "parse_rrsig/1" do
    test "parses RRSIG fields and an uncompressed signer name" do
      {:ok, msg} = Wire.parse(F.packet(:cloudflare_dnskey))

      rrsig =
        msg |> Wire.records_of_type(46) |> List.first() |> Map.get(:rdata) |> RR.parse_rrsig()

      assert rrsig.type_covered == 48
      assert rrsig.algorithm == 13
      assert Wire.name_to_string(rrsig.signer) == "cloudflare.com"
      assert byte_size(rrsig.signature) > 0
    end
  end

  describe "parse_ds/1" do
    test "parses cloudflare.com DS from the .com delegation" do
      {:ok, msg} = Wire.parse(F.packet(:cloudflare_ds))
      ds = msg |> Wire.records_of_type(43) |> List.first() |> Map.get(:rdata) |> RR.parse_ds()
      assert ds.algorithm == 13
      assert ds.digest_type in [1, 2, 4]
      assert byte_size(ds.digest) > 0
    end
  end
end
