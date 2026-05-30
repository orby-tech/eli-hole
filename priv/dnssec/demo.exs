# Live DNSSEC engine demo.
#
# Part 1 manually verifies the root anchor and individual RRSIG/DS links against
# real zones. Part 2 runs the full chain-of-trust Validator (root → name) live.
#
#   make dnssec.demo                 # uses 8.8.8.8
#   UPSTREAM=1.1.1.1 make dnssec.demo

alias EliHole.DNSSEC.{Client, Crypto, RR, TrustAnchor, Validator, Wire}

upstream =
  System.get_env("UPSTREAM", "8.8.8.8")
  |> String.to_charlist()
  |> :inet.parse_address()
  |> then(fn {:ok, ip} -> ip end)

# DNSSEC RR type numbers
a_type = 1
dnskey_type = 48

defmodule Demo do
  def query(domain, type, upstream) do
    id = :rand.uniform(65_535)
    packet = Wire.build_query(domain, type, id)
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    :gen_udp.send(sock, upstream, 53, packet)
    {:ok, {_, _, resp}} = :gen_udp.recv(sock, 0, 5_000)
    :gen_udp.close(sock)
    {:ok, msg} = Wire.parse(resp)
    msg
  end

  def dnskeys(msg), do: msg |> Wire.records_of_type(48) |> Enum.map(&RR.parse_dnskey(&1.rdata))

  def rrsig(msg, covered) do
    msg
    |> Wire.records_of_type(46)
    |> Enum.map(&RR.parse_rrsig(&1.rdata))
    |> Enum.find(&(&1.type_covered == covered))
  end

  def find_key(keys, rrsig), do: Enum.find(keys, &(RR.key_tag(&1) == rrsig.key_tag))

  def mark(true), do: IO.ANSI.green() <> "SECURE ✓" <> IO.ANSI.reset()
  def mark(false), do: IO.ANSI.red() <> "BOGUS  ✗" <> IO.ANSI.reset()
end



IO.puts("\n=== EliHole DNSSEC engine — live demo (upstream #{:inet.ntoa(upstream)}) ===\n")

# 1. Root trust anchor: the live root KSK must hash to a hardcoded DS anchor.
root = Demo.query(".", dnskey_type, upstream)
root_keys = Demo.dnskeys(root)

for anchor <- TrustAnchor.root_ds() do
  ksk = Enum.find(root_keys, &(RR.key_tag(&1) == anchor.key_tag))
  status = ksk && Crypto.verify_ds(anchor, ksk, [])
  IO.puts("root anchor KSK #{anchor.key_tag}: #{Demo.mark(status == true)}  (DS digest matches live root DNSKEY)")
end

# 2. Per-zone: DNSKEY self-signature (KSK over DNSKEY RRset) + A RRSIG (ZSK over A RRset).
for domain <- ["cloudflare.com", "nlnetlabs.nl", "ietf.org", "internetsociety.org"] do
  IO.puts("\n--- #{domain} ---")

  kmsg = Demo.query(domain, dnskey_type, upstream)
  keys = Demo.dnskeys(kmsg)
  key_sig = Demo.rrsig(kmsg, dnskey_type)
  ksk = key_sig && Demo.find_key(keys, key_sig)
  algo = ksk && ksk.algorithm
  IO.puts("  DNSKEY self-sig (KSK #{key_sig && key_sig.key_tag}, alg #{algo}): #{Demo.mark(ksk && Crypto.verify_rrsig(key_sig, Wire.records_of_type(kmsg, dnskey_type), ksk))}")

  amsg = Demo.query(domain, a_type, upstream)
  a_sig = Demo.rrsig(amsg, a_type)
  a_rrset = Wire.records_of_type(amsg, a_type)

  if a_sig && a_rrset != [] do
    zsk = Demo.find_key(keys, a_sig)
    ok = zsk && Crypto.verify_rrsig(a_sig, a_rrset, zsk)
    IO.puts("  A RRSIG (ZSK #{a_sig.key_tag}, alg #{a_sig.algorithm}): #{Demo.mark(ok == true)}")

    # tamper demo: flip one byte of the first A record → signature must reject
    [rr | rest] = a_rrset
    <<b, tail::binary>> = rr.rdata
    tampered = [%{rr | rdata: <<Bitwise.bxor(b, 1), tail::binary>>} | rest]
    IO.puts("  A RRSIG over TAMPERED RRset: #{Demo.mark(zsk && Crypto.verify_rrsig(a_sig, tampered, zsk))}  (expected BOGUS)")
  else
    IO.puts("  (no signed A RRset returned)")
  end
end

# Part 2: full chain-of-trust validation (root → name) via the Validator, fetching
# DNSKEY/DS live through Client. Returns {:secure, signer} | {:insecure, _} | {:bogus, _}.
IO.puts("\n=== Full chain-of-trust validation (Validator, live) ===")

for domain <- ["cloudflare.com", "www.cloudflare.com", "nlnetlabs.nl", "ietf.org"] do
  result =
    case Client.query(domain, a_type) do
      {:ok, answer} -> Validator.validate(domain, a_type, answer, fetch: &Client.query/2)
      {:error, reason} -> {:fetch_error, reason}
    end

  IO.puts("  #{String.pad_trailing(domain, 22)} → #{inspect(result)}")
end

IO.puts("")
