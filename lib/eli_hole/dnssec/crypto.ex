defmodule EliHole.DNSSEC.Crypto do
  @moduledoc """
  Signature and digest verification for DNSSEC, on top of Erlang `:crypto`.

  Two gotchas handled here:

    * `:crypto.verify(:ecdsa, …)` expects a DER-encoded `SEQUENCE{r, s}`, but DNSSEC
      carries the signature as raw fixed-width `r || s` (RFC 6605) — so we DER-wrap it.
    * EdDSA uses `:none` as the digest type and the raw 64/114-byte signature.
  """

  alias EliHole.DNSSEC.{Canonical, RR}
  alias EliHole.DNSSEC.RR.{DNSKEY, DS, RRSIG}

  @doc """
  Verify that `rrsig` (an `%RR.RRSIG{}`) over `rrset` (list of `%Wire.RR{}`) was made
  by `dnskey` (an `%RR.DNSKEY{}`). Returns `true`/`false`.

  Checks algorithm + key-tag linkage, then the cryptographic signature. Does NOT check
  inception/expiration time — that is the validator's job (Loop 2).
  """
  def verify_rrsig(%RRSIG{} = rrsig, rrset, %DNSKEY{} = dnskey) when is_list(rrset) do
    with true <- rrsig.algorithm == dnskey.algorithm,
         true <- rrsig.key_tag == RR.key_tag(dnskey),
         {:ok, family, key} <- RR.to_crypto_key(dnskey) do
      data = Canonical.signing_input(rrsig, rrset)
      verify_signature(family, dnskey.algorithm, data, rrsig.signature, key)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Verify that a DS record delegates to `dnskey` (RFC 4034 §5.1.4): the DS digest must
  equal `hash(canonical_owner_name || DNSKEY_RDATA)`, with matching key tag + algorithm.
  `owner` is the DNSKEY owner name as a label list (the zone apex).
  """
  def verify_ds(%DS{} = ds, %DNSKEY{} = dnskey, owner) when is_list(owner) do
    with true <- ds.key_tag == RR.key_tag(dnskey),
         true <- ds.algorithm == dnskey.algorithm,
         {:ok, hash_alg} <- ds_hash_algorithm(ds.digest_type) do
      digest = :crypto.hash(hash_alg, Canonical.name_wire(owner) <> dnskey.rdata)
      :crypto.hash_equals(digest, ds.digest)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  # --- signature dispatch ---

  defp verify_signature(:rsa, alg, data, sig, [e, n]) do
    :crypto.verify(:rsa, rsa_hash(alg), data, sig, [e, n])
  end

  defp verify_signature(:ecdsa, alg, data, sig, {point, curve}) do
    der = ecdsa_raw_to_der(sig)
    :crypto.verify(:ecdsa, ecdsa_hash(alg), data, der, [point, curve])
  end

  defp verify_signature(:eddsa, _alg, data, sig, {pubkey, curve}) do
    :crypto.verify(:eddsa, :none, data, sig, [pubkey, curve])
  end

  defp rsa_hash(8), do: :sha256
  defp rsa_hash(10), do: :sha512

  defp ecdsa_hash(13), do: :sha256
  defp ecdsa_hash(14), do: :sha384

  defp ds_hash_algorithm(1), do: {:ok, :sha}
  defp ds_hash_algorithm(2), do: {:ok, :sha256}
  defp ds_hash_algorithm(4), do: {:ok, :sha384}
  defp ds_hash_algorithm(_), do: {:error, :unsupported_digest_type}

  # Raw fixed-width r||s (RFC 6605) → DER SEQUENCE { INTEGER r, INTEGER s }.
  defp ecdsa_raw_to_der(sig) do
    half = div(byte_size(sig), 2)
    <<r::binary-size(half), s::binary-size(half)>> = sig
    r_der = der_integer(r)
    s_der = der_integer(s)
    body = r_der <> s_der
    <<0x30>> <> der_length(byte_size(body)) <> body
  end

  defp der_integer(bytes) do
    trimmed = trim_leading_zeros(bytes)
    # Prepend 0x00 if the high bit is set, so the integer stays positive.
    payload =
      case trimmed do
        <<msb, _::binary>> when msb >= 0x80 -> <<0>> <> trimmed
        _ -> trimmed
      end

    <<0x02>> <> der_length(byte_size(payload)) <> payload
  end

  defp trim_leading_zeros(<<0, rest::binary>>) when byte_size(rest) > 0,
    do: trim_leading_zeros(rest)

  defp trim_leading_zeros(bytes), do: bytes

  defp der_length(len) when len < 0x80, do: <<len>>
  defp der_length(len) when len < 0x100, do: <<0x81, len>>
  defp der_length(len), do: <<0x82, len::16>>
end
