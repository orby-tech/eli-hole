defmodule EliHole.DNSSEC.Wire do
  @moduledoc """
  Low-level DNS wire-format parser/encoder for DNSSEC validation.

  `:inet_dns` decodes message framing but returns DNSSEC RDATA as opaque blobs
  and hides the AD/CD bits, so DNSSEC needs its own parser. This module decodes a
  raw DNS message into `%Message{}` of `%RR{}` where `rdata` is the **raw RDATA
  bytes** (required intact for signature canonicalization) and `name` is a list of
  label binaries (original case; down-casing happens in `Canonical`).

  It also builds an EDNS0 query with the DO (DNSSEC OK) bit set so upstreams
  return RRSIG/DNSKEY/DS records.
  """

  import Bitwise

  defmodule RR do
    @moduledoc "One resource record. `name` = list of label binaries, `rdata` = raw bytes."
    defstruct [:name, :type, :class, :ttl, :rdata]
  end

  defmodule Question do
    @moduledoc false
    defstruct [:name, :type, :class]
  end

  defmodule Message do
    @moduledoc false
    defstruct [
      :id,
      :qr,
      :opcode,
      :aa,
      :tc,
      :rd,
      :ra,
      :ad,
      :cd,
      :rcode,
      questions: [],
      answers: [],
      authority: [],
      additional: []
    ]
  end

  @doc "Parse a raw DNS message binary into a `%Message{}`. Returns `{:ok, msg}` or `{:error, reason}`."
  def parse(packet) when is_binary(packet) do
    <<id::16, qr::1, opcode::4, aa::1, tc::1, rd::1, ra::1, _z::1, ad::1, cd::1, rcode::4,
      qdcount::16, ancount::16, nscount::16, arcount::16, _rest::binary>> = packet

    pos = 12
    {questions, pos} = parse_questions(packet, pos, qdcount, [])
    {answers, pos} = parse_rrs(packet, pos, ancount, [])
    {authority, pos} = parse_rrs(packet, pos, nscount, [])
    {additional, _pos} = parse_rrs(packet, pos, arcount, [])

    {:ok,
     %Message{
       id: id,
       qr: qr == 1,
       opcode: opcode,
       aa: aa == 1,
       tc: tc == 1,
       rd: rd == 1,
       ra: ra == 1,
       ad: ad == 1,
       cd: cd == 1,
       rcode: rcode,
       questions: questions,
       answers: answers,
       authority: authority,
       additional: additional
     }}
  rescue
    e -> {:error, e}
  end

  @doc "Collect every RR of a given type across the answer, authority and additional sections."
  def records_of_type(%Message{} = msg, type) when is_integer(type) do
    (msg.answers ++ msg.authority ++ msg.additional)
    |> Enum.filter(&(&1.type == type))
  end

  @doc """
  Build a DNS query for `domain` (binary, e.g. "cloudflare.com") and `type` (integer)
  with an EDNS0 OPT record carrying the DO bit. `id` is the 16-bit query id.
  """
  def build_query(domain, type, id) when is_binary(domain) and is_integer(type) do
    header =
      <<id::16, 0::1, 0::4, 0::1, 0::1, 1::1, 0::1, 0::1, 0::1, 0::1, 0::4, 1::16, 0::16, 0::16,
        1::16>>

    qname = encode_name(domain)
    question = qname <> <<type::16, 1::16>>

    # OPT: root name, type=41, udp payload=4096, ext-rcode/version=0, flags=0x8000 (DO set), rdlen=0
    opt = <<0, 41::16, 4096::16, 0, 0, 0x8000::16, 0::16>>
    header <> question <> opt
  end

  @doc "Encode a dotted domain string into length-prefixed wire labels (no compression)."
  def encode_name(domain) when is_binary(domain) do
    case String.trim_trailing(domain, ".") do
      "" ->
        <<0>>

      d ->
        Enum.reduce(String.split(d, "."), <<>>, fn label, acc ->
          acc <> <<byte_size(label)>> <> label
        end) <> <<0>>
    end
  end

  @doc "Render a label list back to a lowercase dotted string (root = \".\")."
  def name_to_string([]), do: "."
  def name_to_string([""]), do: "."

  def name_to_string(labels) when is_list(labels) do
    labels |> Enum.map_join(".", &String.downcase/1)
  end

  # --- internal parsing ---

  defp parse_questions(_packet, pos, 0, acc), do: {Enum.reverse(acc), pos}

  defp parse_questions(packet, pos, n, acc) do
    {name, pos} = decode_name(packet, pos)
    <<_::binary-size(pos), type::16, class::16, _::binary>> = packet
    q = %Question{name: name, type: type, class: class}
    parse_questions(packet, pos + 4, n - 1, [q | acc])
  end

  defp parse_rrs(_packet, pos, 0, acc), do: {Enum.reverse(acc), pos}

  defp parse_rrs(packet, pos, n, acc) do
    {name, pos} = decode_name(packet, pos)
    <<_::binary-size(pos), type::16, class::16, ttl::32, rdlen::16, _::binary>> = packet
    rdata = binary_part(packet, pos + 10, rdlen)
    rr = %RR{name: name, type: type, class: class, ttl: ttl, rdata: rdata}
    parse_rrs(packet, pos + 10 + rdlen, n - 1, [rr | acc])
  end

  # Decode a (possibly compressed) domain name. Returns {labels, position_after_name_in_stream}.
  # `seen` holds already-followed pointer targets so a self/cyclic compression pointer in a
  # hostile packet raises (caught by parse/1) instead of recursing forever.
  defp decode_name(packet, pos), do: decode_name(packet, pos, [], MapSet.new())

  defp decode_name(packet, pos, _acc, _seen) when pos >= byte_size(packet),
    do: raise(ArgumentError, "name offset out of bounds")

  defp decode_name(packet, pos, acc, seen) do
    <<_::binary-size(pos), len, _::binary>> = packet

    cond do
      len == 0 ->
        {Enum.reverse(acc), pos + 1}

      (len &&& 0xC0) == 0xC0 ->
        <<_::binary-size(pos), ptr16::16, _::binary>> = packet
        target = ptr16 &&& 0x3FFF

        if target >= byte_size(packet) or MapSet.member?(seen, target) do
          raise ArgumentError, "name compression pointer loop or out-of-bounds target"
        end

        {labels, _} = decode_name(packet, target, [], MapSet.put(seen, target))
        {Enum.reverse(acc) ++ labels, pos + 2}

      len <= 63 ->
        label = binary_part(packet, pos + 1, len)
        decode_name(packet, pos + 1 + len, [label | acc], seen)

      true ->
        raise ArgumentError, "invalid label length octet #{len}"
    end
  end
end
