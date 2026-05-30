defmodule EliHole.DNSSEC.RR do
  @moduledoc """
  Parsers for DNSSEC-specific RDATA (DNSKEY, RRSIG, DS, NSEC, NSEC3), the RFC 4034
  Appendix B key-tag computation, and conversion of a DNSKEY public key into the
  term shape `:crypto.verify/5` expects.

  Each parser takes the raw RDATA bytes (as produced by `EliHole.DNSSEC.Wire`).
  """

  import Bitwise

  alias EliHole.DNSSEC.Wire

  @typedoc "DNSSEC algorithm number (8 RSASHA256, 10 RSASHA512, 13 ECDSAP256, 14 ECDSAP384, 15 Ed25519, 16 Ed448)"
  @type algorithm :: non_neg_integer()

  defmodule DNSKEY do
    @moduledoc false
    # rdata kept verbatim — needed for key-tag and DS digest computation.
    defstruct [:flags, :protocol, :algorithm, :public_key, :rdata]
  end

  defmodule RRSIG do
    @moduledoc false
    defstruct [
      :type_covered,
      :algorithm,
      :labels,
      :original_ttl,
      :expiration,
      :inception,
      :key_tag,
      :signer,
      :signature
    ]
  end

  defmodule DS do
    @moduledoc false
    defstruct [:key_tag, :algorithm, :digest_type, :digest]
  end

  defmodule NSEC do
    @moduledoc false
    defstruct [:next_name, :types]
  end

  defmodule NSEC3 do
    @moduledoc false
    defstruct [:hash_algorithm, :flags, :iterations, :salt, :next_hashed, :types]
  end

  @doc "Parse DNSKEY RDATA (RFC 4034 §2.1)."
  def parse_dnskey(<<flags::16, protocol::8, algorithm::8, public_key::binary>> = rdata) do
    %DNSKEY{
      flags: flags,
      protocol: protocol,
      algorithm: algorithm,
      public_key: public_key,
      rdata: rdata
    }
  end

  @doc "Is this DNSKEY a Secure Entry Point (KSK)? SEP bit = 0x0001 of Flags (RFC 4034 §2.1.1)."
  def sep?(%DNSKEY{flags: flags}), do: (flags &&& 0x0001) == 0x0001

  @doc "Parse RRSIG RDATA (RFC 4034 §3.1). Signer name is uncompressed."
  def parse_rrsig(
        <<type_covered::16, algorithm::8, labels::8, original_ttl::32, expiration::32,
          inception::32, key_tag::16, rest::binary>>
      ) do
    {signer_labels, signer_len} = decode_uncompressed_name(rest, 0, [])
    <<_signer::binary-size(signer_len), signature::binary>> = rest

    %RRSIG{
      type_covered: type_covered,
      algorithm: algorithm,
      labels: labels,
      original_ttl: original_ttl,
      expiration: expiration,
      inception: inception,
      key_tag: key_tag,
      signer: signer_labels,
      signature: signature
    }
  end

  @doc "Parse DS RDATA (RFC 4034 §5.1)."
  def parse_ds(<<key_tag::16, algorithm::8, digest_type::8, digest::binary>>) do
    %DS{key_tag: key_tag, algorithm: algorithm, digest_type: digest_type, digest: digest}
  end

  @doc "Parse NSEC RDATA (RFC 4034 §4.1). Next name is uncompressed; remainder is the type bitmap."
  def parse_nsec(rdata) do
    {next_name, len} = decode_uncompressed_name(rdata, 0, [])
    <<_::binary-size(len), bitmaps::binary>> = rdata
    %NSEC{next_name: next_name, types: parse_type_bitmaps(bitmaps, [])}
  end

  @doc "Parse NSEC3 RDATA (RFC 5155 §3.2)."
  def parse_nsec3(
        <<hash_algorithm::8, flags::8, iterations::16, salt_len::8, salt::binary-size(salt_len),
          hash_len::8, next_hashed::binary-size(hash_len), bitmaps::binary>>
      ) do
    %NSEC3{
      hash_algorithm: hash_algorithm,
      flags: flags,
      iterations: iterations,
      salt: salt,
      next_hashed: next_hashed,
      types: parse_type_bitmaps(bitmaps, [])
    }
  end

  @doc """
  Key tag of a DNSKEY (RFC 4034 Appendix B) — used to link RRSIG/DS to a key.
  Algorithm 1 (RSA/MD5) uses a different rule; unsupported here (deprecated).
  """
  def key_tag(%DNSKEY{rdata: rdata}), do: key_tag(rdata)

  def key_tag(rdata) when is_binary(rdata) do
    ac =
      rdata
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {byte, i}, ac ->
        if rem(i, 2) == 0, do: ac + (byte <<< 8), else: ac + byte
      end)

    ac = ac + (ac >>> 16 &&& 0xFFFF)
    ac &&& 0xFFFF
  end

  @doc """
  Convert a DNSKEY into the public-key term `:crypto.verify/5` expects for its algorithm.
  Returns `{:ok, family, key}` or `{:error, {:unsupported_algorithm, n}}`.

  * RSA (8, 10) → `{:rsa, [E, N]}` (RFC 3110 exponent-length encoding)
  * ECDSA (13, 14) → `{:ecdsa, {point, curve}}` (point gets the 0x04 uncompressed prefix)
  * EdDSA (15, 16) → `{:eddsa, {pubkey, curve}}`
  """
  def to_crypto_key(%DNSKEY{algorithm: alg, public_key: pk}) when alg in [8, 10] do
    {e, n} = parse_rsa_public_key(pk)
    {:ok, :rsa, [:binary.decode_unsigned(e), :binary.decode_unsigned(n)]}
  end

  def to_crypto_key(%DNSKEY{algorithm: 13, public_key: <<x_y::binary-size(64)>>}),
    do: {:ok, :ecdsa, {<<4>> <> x_y, :secp256r1}}

  def to_crypto_key(%DNSKEY{algorithm: 14, public_key: <<x_y::binary-size(96)>>}),
    do: {:ok, :ecdsa, {<<4>> <> x_y, :secp384r1}}

  def to_crypto_key(%DNSKEY{algorithm: 15, public_key: pk}),
    do: {:ok, :eddsa, {pk, :ed25519}}

  def to_crypto_key(%DNSKEY{algorithm: 16, public_key: pk}),
    do: {:ok, :eddsa, {pk, :ed448}}

  def to_crypto_key(%DNSKEY{algorithm: alg}), do: {:error, {:unsupported_algorithm, alg}}

  @doc "Render a label list to a lowercase dotted string (delegates to `Wire`)."
  def name_to_string(labels), do: Wire.name_to_string(labels)

  # --- RSA RFC 3110 exponent/modulus split ---
  defp parse_rsa_public_key(<<0::8, elen::16, exp::binary-size(elen), mod::binary>>),
    do: {exp, mod}

  defp parse_rsa_public_key(<<elen::8, exp::binary-size(elen), mod::binary>>) when elen > 0,
    do: {exp, mod}

  # --- uncompressed name decoder (for RDATA-embedded names) ---
  # DNSSEC forbids compression in RRSIG signer / NSEC next-name, so no pointer handling.
  defp decode_uncompressed_name(<<0, _::binary>>, consumed, acc),
    do: {Enum.reverse(acc), consumed + 1}

  defp decode_uncompressed_name(<<len, rest::binary>>, consumed, acc) when len <= 63 do
    <<label::binary-size(len), tail::binary>> = rest
    decode_uncompressed_name(tail, consumed + 1 + len, [label | acc])
  end

  # A length octet > 63 here means a compression pointer or garbage. RDATA names in DNSSEC
  # records must be uncompressed, so this is malformed input — raise (callers handling
  # untrusted packets rescue) rather than fall through to a FunctionClauseError.
  defp decode_uncompressed_name(_bin, _consumed, _acc),
    do: raise(ArgumentError, "compressed or malformed name in RDATA")

  # --- NSEC/NSEC3 type bitmap (RFC 4034 §4.1.2) ---
  defp parse_type_bitmaps(<<>>, acc), do: Enum.reverse(acc)

  defp parse_type_bitmaps(<<window::8, len::8, bits::binary-size(len), rest::binary>>, acc) do
    types =
      bits
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {byte, byte_idx} ->
        for bit <- 0..7, (byte >>> (7 - bit) &&& 1) == 1, do: window * 256 + byte_idx * 8 + bit
      end)

    parse_type_bitmaps(rest, Enum.reverse(types) ++ acc)
  end
end
