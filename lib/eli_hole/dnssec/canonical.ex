defmodule EliHole.DNSSEC.Canonical do
  @moduledoc """
  Canonical RR forms and the RRSIG signing-input construction (RFC 4034 §3.1.8.1,
  §6, with the RFC 6840 §5.1 down-casing correction).

  Critical rules:

    * RR owner names are down-cased and uncompressed.
    * The TTL in the signing input is the RRSIG **Original TTL**, not the packet TTL.
    * RDATA-embedded names are down-cased only for the RFC 6840 type list; NSEC's
      next-name is NOT down-cased, RRSIG's signer name IS.
    * The RRset is sorted by canonical RDATA, treated as left-justified unsigned
      octets where "absence of an octet sorts before a zero octet" — which is
      exactly Erlang's binary term order.
  """

  alias EliHole.DNSSEC.RR.RRSIG
  alias EliHole.DNSSEC.Wire.RR

  # RFC 4034 §6.2 as narrowed by RFC 6840 §5.1: types whose RDATA-embedded domain
  # names must be down-cased for canonicalization. NSEC (47) and HINFO are excluded;
  # RRSIG's signer name is handled separately in the signing input.
  @downcase_name_types %{
    # NS
    2 => :single,
    # CNAME
    5 => :single,
    # SOA (mname, rname, then fixed fields)
    6 => :soa,
    # PTR
    12 => :single,
    # MX (16-bit pref, name)
    15 => :mx,
    # DNAME
    39 => :single
  }

  @doc """
  Build the byte string that the RRSIG signature is computed over (RFC 4034 §3.1.8.1):

      RRSIG_RDATA(without signature) || sorted( canonical RR(i) )

  `rrset` is the list of `%Wire.RR{}` covered by `rrsig`.
  """
  def signing_input(%RRSIG{} = rrsig, rrset) when is_list(rrset) do
    rrsig_rdata_prefix(rrsig) <> canonical_rrset(rrsig, rrset)
  end

  @doc "Canonical wire form of a name (list of labels): down-cased, length-prefixed, root-terminated."
  def name_wire(labels) when is_list(labels) do
    Enum.reduce(labels, <<>>, fn label, acc ->
      low = String.downcase(label)
      acc <> <<byte_size(low)>> <> low
    end) <> <<0>>
  end

  # RRSIG RDATA up to and including the signer name, signature field omitted, signer down-cased.
  defp rrsig_rdata_prefix(%RRSIG{} = s) do
    <<s.type_covered::16, s.algorithm::8, s.labels::8, s.original_ttl::32, s.expiration::32,
      s.inception::32, s.key_tag::16>> <> name_wire(s.signer)
  end

  defp canonical_rrset(%RRSIG{} = rrsig, rrset) do
    rrset
    |> Enum.map(fn %RR{} = rr ->
      owner = name_wire(wildcard_owner(rr.name, rrsig.labels))
      rdata = canonical_rdata(rr.type, rr.rdata)

      record =
        owner <>
          <<rr.type::16, rr.class::16, rrsig.original_ttl::32, byte_size(rdata)::16>> <> rdata

      {rdata, record}
    end)
    |> Enum.sort_by(fn {rdata, _record} -> rdata end)
    |> Enum.map_join("", fn {_rdata, record} -> record end)
  end

  # RFC 4035 §5.3.2: when the RRSIG Labels count is fewer than the owner's label count, the
  # RRset was synthesized from a wildcard, and the canonical owner used for signing is "*."
  # prepended to the rightmost `labels` labels (not the queried name).
  defp wildcard_owner(name, labels) when length(name) > labels,
    do: ["*" | Enum.take(name, -labels)]

  defp wildcard_owner(name, _labels), do: name

  @doc """
  Canonical RDATA for a type. For types with embedded names in the RFC 6840 down-case
  list, the names are lower-cased; all other types (A, AAAA, DNSKEY, DS, TXT, NSEC3, …)
  pass through unchanged. NSEC (47) is intentionally identity (next-name not down-cased).
  """
  def canonical_rdata(type, rdata) do
    case Map.get(@downcase_name_types, type) do
      nil ->
        rdata

      :single ->
        name_wire(decode_name(rdata))

      :mx ->
        <<pref::16, rest::binary>> = rdata
        <<pref::16>> <> name_wire(decode_name(rest))

      :soa ->
        canonical_soa(rdata)
    end
  end

  # SOA: MNAME (name) RNAME (name) then 5x 32-bit fixed fields — both names down-cased.
  defp canonical_soa(rdata) do
    {mname, rest1} = decode_name_with_rest(rdata)
    {rname, rest2} = decode_name_with_rest(rest1)
    name_wire(mname) <> name_wire(rname) <> rest2
  end

  # Decode an uncompressed name from the start of a binary, discarding the remainder.
  defp decode_name(bin), do: elem(decode_name_with_rest(bin), 0)

  defp decode_name_with_rest(bin), do: decode_name_with_rest(bin, [])
  defp decode_name_with_rest(<<0, rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp decode_name_with_rest(<<len, rest::binary>>, acc) when len <= 63 do
    <<label::binary-size(len), tail::binary>> = rest
    decode_name_with_rest(tail, [label | acc])
  end
end
