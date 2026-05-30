defmodule EliHole.DNSSEC.Denial do
  @moduledoc """
  Authenticated denial-of-existence primitives (RFC 4034 NSEC, RFC 5155 NSEC3).

  Pure functions over `EliHole.DNSSEC.Wire.RR` records of type NSEC (47) / NSEC3 (50).
  The validator uses these to prove that a DS record is genuinely absent (an unsigned
  delegation → `:insecure`) rather than stripped by an attacker (→ `:bogus`), closing
  the DNSSEC downgrade hole.

  Type numbers in NSEC/NSEC3 bitmaps that matter here: NS=2, SOA=6, DS=43.
  """

  import Bitwise

  alias EliHole.DNSSEC.Canonical
  alias EliHole.DNSSEC.RR
  alias EliHole.DNSSEC.Wire

  @ns 2
  @soa 6
  @ds 43

  @doc """
  NSEC3 hashed owner name (RFC 5155 §5): iterated SHA-1 of the canonical (lower-cased,
  wire-format) name concatenated with `salt`. `iterations` is the number of ADDITIONAL
  hashes beyond the first, so the hash is applied `iterations + 1` times.
  """
  def nsec3_hash(labels, salt, iterations) when is_list(labels) do
    wire = Canonical.name_wire(labels)

    Enum.reduce(0..iterations, nil, fn
      0, _acc -> :crypto.hash(:sha, wire <> salt)
      _i, acc -> :crypto.hash(:sha, acc <> salt)
    end)
  end

  @doc "Hash parameters `{salt, iterations, hash_algorithm}` shared by a zone's NSEC3 RRs."
  def nsec3_params(%Wire.RR{rdata: rdata}) do
    n = RR.parse_nsec3(rdata)
    {n.salt, n.iterations, n.hash_algorithm}
  end

  @doc "Does this NSEC3 RR's owner hash equal `target_hash` (the name's hash exists)?"
  def nsec3_matches?(%Wire.RR{} = rr, target_hash) do
    owner_hash(rr) == target_hash
  end

  @doc """
  Does this NSEC3 RR's (owner_hash, next_hash) interval strictly cover `target_hash`?
  Handles the wrap-around at the zone's last NSEC3 (owner_hash >= next_hash).
  """
  def nsec3_covers?(%Wire.RR{rdata: rdata} = rr, target_hash) do
    o = owner_hash(rr)
    n = RR.parse_nsec3(rdata).next_hashed
    cover_between?(o, n, target_hash)
  end

  @doc "Is the NSEC3 Opt-Out flag set (RFC 5155 §3.1.2.1)? Permits unsigned delegations in the gap."
  def nsec3_opt_out?(%Wire.RR{rdata: rdata}), do: (RR.parse_nsec3(rdata).flags &&& 0x01) == 0x01

  @doc "DS-NODATA proof: this NSEC3 matches the delegation name, has NS set, DS and SOA clear."
  def nsec3_nodata_ds?(%Wire.RR{rdata: rdata}) do
    types = RR.parse_nsec3(rdata).types
    @ns in types and @ds not in types and @soa not in types
  end

  @doc "DS-NODATA proof via NSEC (no hashing): NS set, DS and SOA clear (SOA-clear rejects a child apex)."
  def nsec_nodata_ds?(%Wire.RR{rdata: rdata}) do
    types = RR.parse_nsec(rdata).types
    @ns in types and @ds not in types and @soa not in types
  end

  @doc "Does this NSEC3 RR (NODATA) match `name` and have `type` absent (and not a CNAME)?"
  def nsec3_nodata_type?(%Wire.RR{rdata: rdata} = rr, target_hash, type) do
    nsec3_matches?(rr, target_hash) and type_absent?(RR.parse_nsec3(rdata).types, type)
  end

  @doc "NSEC NODATA proof: owner == `name`, `type` (and CNAME) absent from the bitmap."
  def nsec_nodata_type?(%Wire.RR{name: name, rdata: rdata}, name_labels, type) do
    downcase(name) == name_labels and type_absent?(RR.parse_nsec(rdata).types, type)
  end

  @doc "NSEC NXDOMAIN proof: this NSEC's (owner, next_name) interval canonically covers `name`."
  def nsec_covers?(%Wire.RR{name: owner, rdata: rdata}, name_labels) do
    o = downcase(owner)
    n = downcase(RR.parse_nsec(rdata).next_name)
    cover_name?(o, n, name_labels)
  end

  @doc """
  Canonical DNS name order (RFC 4034 §6.1): compare labels right-to-left as lower-cased
  octet strings; a name that is a proper suffix sorts first. Returns `:lt | :eq | :gt`.
  """
  def name_compare(a, b) when is_list(a) and is_list(b) do
    cmp_labels(Enum.reverse(downcase(a)), Enum.reverse(downcase(b)))
  end

  # --- internals ---

  @cname 5

  defp type_absent?(types, type), do: type not in types and @cname not in types

  defp downcase(labels), do: Enum.map(labels, &String.downcase/1)

  # Cover `name` by the (owner, next) interval, exclusive, with wrap-around at the apex
  # (owner_name >= next_name, i.e. next wraps to the zone's first name).
  defp cover_name?(owner, next, name) do
    case name_compare(owner, next) do
      :lt -> name_compare(owner, name) == :lt and name_compare(name, next) == :lt
      _ -> name_compare(owner, name) == :lt or name_compare(name, next) == :lt
    end
  end

  defp cmp_labels([], []), do: :eq
  defp cmp_labels([], _), do: :lt
  defp cmp_labels(_, []), do: :gt

  defp cmp_labels([x | xs], [y | ys]) do
    cond do
      x < y -> :lt
      x > y -> :gt
      true -> cmp_labels(xs, ys)
    end
  end

  # --- internals ---

  defp owner_hash(%Wire.RR{name: [label | _]}) do
    Base.hex_decode32!(String.upcase(label), padding: false)
  rescue
    _ -> <<>>
  end

  defp owner_hash(_), do: <<>>

  # Strict interval cover with wrap-around. Empty owner hash (decode failure) covers nothing.
  defp cover_between?(<<>>, _n, _t), do: false

  defp cover_between?(o, n, t) when o < n, do: o < t and t < n
  defp cover_between?(o, n, t) when o >= n, do: t > o or t < n
end
