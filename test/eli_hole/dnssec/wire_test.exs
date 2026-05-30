defmodule EliHole.DNSSEC.WireTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.Wire
  alias EliHole.DNSSECFixtures, as: F

  describe "parse/1" do
    test "decodes header, question and answers from a real DNSKEY response" do
      assert {:ok, msg} = Wire.parse(F.packet(:cloudflare_dnskey))
      assert msg.qr
      assert msg.rcode == 0
      assert [q] = msg.questions
      assert Wire.name_to_string(q.name) == "cloudflare.com"
      assert q.type == 48

      # 2 DNSKEYs + 1 RRSIG in the answer section
      assert length(Enum.filter(msg.answers, &(&1.type == 48))) == 2
      assert length(Enum.filter(msg.answers, &(&1.type == 46))) == 1
    end

    test "follows name compression pointers (www.cloudflare.com)" do
      assert {:ok, msg} = Wire.parse(F.packet(:www_cloudflare_a))
      a_rrs = Enum.filter(msg.answers, &(&1.type == 1))
      assert a_rrs != []
      assert Enum.all?(a_rrs, &(Wire.name_to_string(&1.name) == "www.cloudflare.com"))
      # A RDATA is 4 raw bytes, kept verbatim
      assert Enum.all?(a_rrs, &(byte_size(&1.rdata) == 4))
    end

    test "parses the root DNSKEY response (root owner name)" do
      assert {:ok, msg} = Wire.parse(F.packet(:root_dnskey))
      [q] = msg.questions
      assert Wire.name_to_string(q.name) == "."
      assert Enum.count(msg.answers, &(&1.type == 48)) >= 2
    end

    test "returns {:error, _} on garbage" do
      assert {:error, _} = Wire.parse(<<0, 1, 2, 3>>)
    end

    test "a self-referential compression pointer terminates with an error (no hang)" do
      # header (qdcount=1) + a question whose name is a pointer to its own offset (12 → 0xC00C)
      packet = <<0::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0xC0, 0x0C>>

      task = Task.async(fn -> Wire.parse(packet) end)
      assert {:error, _} = Task.await(task, 1_000)
    end

    test "a cyclic compression pointer chain terminates with an error (no hang)" do
      # name at 12 → 14, name at 14 → 12
      packet = <<0::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0xC0, 14, 0xC0, 12>>

      task = Task.async(fn -> Wire.parse(packet) end)
      assert {:error, _} = Task.await(task, 1_000)
    end
  end

  describe "build_query/3 + encode_name/1" do
    test "builds a query whose framing :inet_dns can decode back" do
      packet = Wire.build_query("example.com", 1, 0x1234)
      assert {:ok, rec} = :inet_dns.decode(packet)
      [q] = :inet_dns.msg(rec, :qdlist)
      assert :inet_dns.dns_query(q, :domain) |> to_string() == "example.com"
      assert :inet_dns.dns_query(q, :type) == :a
      # OPT pseudo-RR present (DO bit query)
      assert :inet_dns.msg(rec, :arlist) != []
    end

    test "build_query round-trips through our own parser with DO semantics" do
      packet = Wire.build_query("cloudflare.com", 48, 42)
      assert {:ok, msg} = Wire.parse(packet)
      assert msg.id == 42
      assert msg.rd
      [q] = msg.questions
      assert Wire.name_to_string(q.name) == "cloudflare.com"
      assert q.type == 48
    end

    test "encode_name produces length-prefixed labels and a root terminator" do
      assert Wire.encode_name("a.bc") == <<1, ?a, 2, ?b, ?c, 0>>
      assert Wire.encode_name(".") == <<0>>
      assert Wire.encode_name("example.com.") == Wire.encode_name("example.com")
    end
  end
end
