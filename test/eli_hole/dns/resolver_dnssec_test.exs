defmodule EliHole.DNS.ResolverDNSSECTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EliHole.DNS.Resolver

  defp build_query(domain, type) do
    header = :inet_dns.make_header(id: 4321, qr: false, opcode: :query, rd: true)
    query = :inet_dns.make_dns_query(domain: String.to_charlist(domain), type: type, class: :in)
    msg = :inet_dns.make_msg(header: header, qdlist: [query])

    case :inet_dns.encode(msg) do
      {:ok, packet} -> packet
      packet when is_binary(packet) -> packet
    end
  end

  describe "enforce_response/4" do
    test ":ok + :secure sets the AD header bit" do
      # flags second octet 0x80 (RA set), AD (0x20) clear
      response = <<0x1234::16, 0x81, 0x80, 0::16, 0::16, 0::16, 0::16>>
      out = Resolver.enforce_response(response, :ok, :secure, <<>>)
      <<_id::16, _f1, f2, _::binary>> = out
      assert (f2 &&& 0x20) == 0x20
    end

    test ":ok + :bogus replaces the answer with SERVFAIL" do
      query = build_query("example.com", :a)
      out = Resolver.enforce_response(<<"the bogus answer bytes">>, :ok, :bogus, query)
      assert {:ok, rec} = :inet_dns.decode(out)
      assert :inet_dns.header(:inet_dns.msg(rec, :header), :rcode) == 2
    end

    test ":insecure leaves the response unchanged" do
      response = <<9, 9, 9, 9, 9>>
      assert Resolver.enforce_response(response, :ok, :insecure, <<>>) == response
    end

    test "non-:ok status is never enforced (blocked/local responses pass through)" do
      response = <<9, 9, 9, 9, 9>>
      assert Resolver.enforce_response(response, :blocked, :bogus, <<>>) == response
      assert Resolver.enforce_response(response, :ok, nil, <<>>) == response
    end
  end
end
