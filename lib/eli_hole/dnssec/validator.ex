defmodule EliHole.DNSSEC.Validator do
  @moduledoc """
  Builds the DNSSEC chain of trust from the hardcoded root anchor down to the zone
  that signed a given answer, and verifies the answer's signature.

  `validate/4` returns one of:

    * `{:secure, signer}` — the answer is signed and the chain validated to the root.
    * `{:insecure, reason}` — a zone cut genuinely has no DS delegation (unsigned zone),
      backed by an authenticated NSEC/NSEC3 proof of DS absence (`prove_ds_absence`).
    * `{:bogus, reason}` — a signature, key linkage, or validity period failed, OR an
      absent DS lacked an authenticated denial (a stripped-DS downgrade is detected).

  The fetcher used to pull DNSKEY/DS records is injectable (`opts[:fetch]`, a
  `fn name, type -> {:ok, %Wire.Message{}} | {:error, term} end`) so the walk can be
  tested offline against captured fixtures; it defaults to `Client.query/2`.

  Time is injectable via `opts[:now]` (unix seconds) for deterministic tests against
  captured (and eventually expiring) signatures.
  """

  alias EliHole.DNSSEC.{Client, Crypto, Denial, RR, TrustAnchor, Wire}
  alias EliHole.DNSSEC.RR.RRSIG

  @dnskey 48
  @ds 43
  @rrsig 46
  @nsec 47
  @nsec3 50
  @soa 6

  # RFC 9276: validators should not honour high NSEC3 iteration counts (CPU DoS). Treat an
  # excessive count as insecure rather than burning cycles hashing.
  @max_nsec3_iterations 100

  @doc "Validate the answer in `answer_msg` for `qname`/`qtype` (qtype = integer RR type)."
  def validate(qname, qtype, %Wire.Message{} = answer_msg, opts \\ []) when is_binary(qname) do
    fetch = Keyword.get(opts, :fetch, &Client.query/2)
    now = Keyword.get(opts, :now, System.os_time(:second))
    qname_labels = name_labels(qname)

    # Only consider RRsets/RRSIGs owned by the queried name, so a message that merely
    # carries a validly-signed RRset for some *other* name cannot be reported :secure.
    case answer_rrsig(answer_msg, qname_labels, qtype) do
      nil ->
        # No signed RRset for the queried name/type — it may still be an authenticated
        # NXDOMAIN/NODATA. Prove the denial (→ :secure) or fall back to :insecure.
        case prove_denial(answer_msg, qname_labels, qtype, fetch, now) do
          :no_denial -> {:insecure, :no_rrsig_in_answer}
          result -> result
        end

      {rrsigs, rrset} ->
        # All RRSIGs over one name share the signing zone; walk it once, then accept if
        # ANY of them verifies under a trusted key (a name may be signed by several keys).
        signer = hd(rrsigs).signer

        case build_chain(signer, fetch, now) do
          {:ok, trusted_keys} -> verify_answer(rrsigs, rrset, trusted_keys, signer, now)
          other -> other
        end
    end
  rescue
    # Malformed fetched/answer data must classify as bogus, never crash the caller.
    e -> {:bogus, {:validation_error, e.__struct__}}
  end

  # --- chain walk (root → signer) ---

  defp build_chain(signer_labels, fetch, now) do
    walk(ancestors(signer_labels), TrustAnchor.root_ds(), fetch, now)
  end

  # Process the head zone, then either stop (it is the signer) or fetch the child's DS
  # and recurse. `trusted_ds` is the DS set delegating to the head zone.
  defp walk([{zone_str, zone_labels, last?} | rest], trusted_ds, fetch, now) do
    case anchor_dnskeys(zone_str, zone_labels, trusted_ds, fetch, now) do
      {:ok, dnskeys} ->
        if last? do
          {:ok, dnskeys}
        else
          [{child_str, child_labels, _} | _] = rest

          case fetch_child_ds(child_str, child_labels, dnskeys, fetch, now) do
            {:ok, child_ds} -> walk(rest, child_ds, fetch, now)
            other -> other
          end
        end

      error ->
        error
    end
  end

  # Verify a zone's DNSKEY RRset (RFC 4035 §5.2): it is trusted if it carries an RRSIG
  # whose *signing* key (a) is present in the set, (b) is itself anchored by a trusted
  # DS, and (c) produced a valid, in-period signature over the RRset. Picking the signer
  # from the RRSIG (not an arbitrary DS-matched key) matters during a KSK rollover, where
  # several DS-matched KSKs are published but only one is the active signer.
  defp anchor_dnskeys(zone_str, zone_labels, trusted_ds, fetch, now) do
    case fetch.(zone_str, @dnskey) do
      {:ok, msg} ->
        dnskeys = parse_dnskeys(msg)
        rrset = Wire.records_of_type(msg, @dnskey)
        sigs = msg |> rrsigs() |> Enum.filter(&(&1.type_covered == @dnskey))

        if dnskey_rrset_anchored?(sigs, dnskeys, rrset, trusted_ds, zone_labels, now) do
          {:ok, dnskeys}
        else
          {:bogus, {:dnskey_rrset_unverified, zone_str}}
        end

      {:error, reason} ->
        {:bogus, {:dnskey_fetch_failed, zone_str, reason}}
    end
  end

  defp dnskey_rrset_anchored?(sigs, dnskeys, rrset, trusted_ds, zone_labels, now) do
    Enum.any?(sigs, fn sig ->
      key = Enum.find(dnskeys, &(RR.key_tag(&1) == sig.key_tag))

      key &&
        Enum.any?(trusted_ds, &Crypto.verify_ds(&1, key, zone_labels)) &&
        within?(sig, now) &&
        Crypto.verify_rrsig(sig, rrset, key)
    end)
  end

  # Fetch the child zone's DS, verify it under the parent's keys. An absent DS must be
  # backed by an authenticated NSEC/NSEC3 proof (→ insecure delegation); an unproven
  # absence is a downgrade attempt (→ bogus).
  defp fetch_child_ds(child_str, child_labels, parent_keys, fetch, now) do
    case fetch.(child_str, @ds) do
      {:ok, msg} ->
        ds_rrset = Wire.records_of_type(msg, @ds)

        cond do
          ds_rrset == [] ->
            prove_ds_absence(msg, child_str, child_labels, parent_keys, now)

          true ->
            ds_sigs = msg |> rrsigs() |> Enum.filter(&(&1.type_covered == @ds))

            if Enum.any?(ds_sigs, &rrsig_validates?(&1, ds_rrset, parent_keys, now)) do
              {:ok, Enum.map(ds_rrset, &RR.parse_ds(&1.rdata))}
            else
              {:bogus, {:ds_rrset_unverified, child_str}}
            end
        end

      {:error, reason} ->
        {:bogus, {:ds_fetch_failed, child_str, reason}}
    end
  end

  # An empty DS RRset is only `:insecure` if the parent authenticated the absence with
  # NSEC/NSEC3; otherwise it is a stripped-DS downgrade (`:bogus`). RFC 4035 §5.2,
  # RFC 5155 §8.6/§8.9.
  defp prove_ds_absence(msg, child_str, child_labels, parent_keys, now) do
    nsec3s = signed_denials(msg, @nsec3, parent_keys, now)
    nsecs = signed_denials(msg, @nsec, parent_keys, now)

    cond do
      nsec3s != [] -> prove_no_ds_nsec3(nsec3s, child_str, child_labels)
      nsecs != [] -> prove_no_ds_nsec(nsecs, child_str, child_labels)
      true -> {:bogus, {:ds_denial_missing, child_str}}
    end
  end

  defp prove_no_ds_nsec3(nsec3s, child_str, child_labels) do
    {salt, iterations, hash_alg} = Denial.nsec3_params(hd(nsec3s))

    cond do
      hash_alg != 1 ->
        {:bogus, {:nsec3_unsupported_hash, child_str}}

      iterations > @max_nsec3_iterations ->
        {:insecure, {:nsec3_iterations_exceeded, child_str}}

      true ->
        prove_no_ds_nsec3_hashed(nsec3s, child_str, child_labels, salt, iterations)
    end
  end

  defp prove_no_ds_nsec3_hashed(nsec3s, child_str, child_labels, salt, iterations) do
    target = Denial.nsec3_hash(child_labels, salt, iterations)

    cond do
      Enum.any?(nsec3s, &(Denial.nsec3_matches?(&1, target) and Denial.nsec3_nodata_ds?(&1))) ->
        {:insecure, {:no_ds_nsec3, child_str}}

      Enum.any?(nsec3s, &(Denial.nsec3_covers?(&1, target) and Denial.nsec3_opt_out?(&1))) ->
        {:insecure, {:no_ds_optout, child_str}}

      true ->
        {:bogus, {:ds_denial_unproven, child_str}}
    end
  end

  defp prove_no_ds_nsec(nsecs, child_str, child_labels) do
    if Enum.any?(nsecs, &(owned_by?(&1, child_labels) and Denial.nsec_nodata_ds?(&1))) do
      {:insecure, {:no_ds_nsec, child_str}}
    else
      {:bogus, {:ds_denial_unproven, child_str}}
    end
  end

  # Authenticated denial-of-existence for the answer (NXDOMAIN / NODATA). Additive and
  # conservative: returns `:secure` only when a parent-signed NSEC/NSEC3 actually proves
  # the name/type is absent; otherwise `:insecure` (never `:bogus`, so unsupported denial
  # styles — e.g. NSEC3 closest-encloser, wildcards — never SERVFAIL a legitimate answer).
  defp prove_denial(msg, qname_labels, qtype, fetch, now) do
    case soa_apex(msg) do
      nil ->
        :no_denial

      apex_labels ->
        case build_chain(apex_labels, fetch, now) do
          {:ok, keys} ->
            if denial_proven?(msg, qname_labels, qtype, keys, now) do
              {:secure, Wire.name_to_string(apex_labels)}
            else
              {:insecure, :denial_unproven}
            end

          _ ->
            {:insecure, :denial_zone_insecure}
        end
    end
  rescue
    # The denial path must never raise into validate/4's bogus rescue: a malformed/injected
    # NSEC/RRSIG record must not turn a legitimate NXDOMAIN/NODATA into SERVFAIL. Degrade to
    # insecure (the pre-Loop-7 behaviour for an unproveable denial).
    _ -> {:insecure, :denial_parse_error}
  end

  defp denial_proven?(msg, qname_labels, qtype, keys, now) do
    nsecs = signed_denials(msg, @nsec, keys, now)
    nsec3s = signed_denials(msg, @nsec3, keys, now)

    nsec_denial?(nsecs, qname_labels, qtype) or nsec3_nodata?(nsec3s, qname_labels, qtype)
  end

  defp nsec_denial?(nsecs, qname_labels, qtype) do
    Enum.any?(nsecs, &Denial.nsec_nodata_type?(&1, qname_labels, qtype)) or
      Enum.any?(nsecs, &Denial.nsec_covers?(&1, qname_labels))
  end

  defp nsec3_nodata?([], _qname_labels, _qtype), do: false

  defp nsec3_nodata?([first | _] = nsec3s, qname_labels, qtype) do
    {salt, iterations, hash_alg} = Denial.nsec3_params(first)

    if hash_alg == 1 and iterations <= @max_nsec3_iterations do
      target = Denial.nsec3_hash(qname_labels, salt, iterations)
      Enum.any?(nsec3s, &Denial.nsec3_nodata_type?(&1, target, qtype))
    else
      false
    end
  end

  defp soa_apex(msg) do
    case Wire.records_of_type(msg, @soa) do
      [%Wire.RR{name: name} | _] -> Enum.map(name, &String.downcase/1)
      [] -> nil
    end
  end

  # NSEC/NSEC3 RRs of `type` whose own RRSIG validates under the parent's keys. Malformed
  # RRSIG records are skipped (not raised) so an injected junk RRSIG cannot discard an
  # otherwise valid denial proof.
  defp signed_denials(msg, type, parent_keys, now) do
    msg
    |> Wire.records_of_type(type)
    |> Enum.filter(fn rr ->
      owner = Enum.map(rr.name, &String.downcase/1)

      msg
      |> Wire.records_of_type(@rrsig)
      |> Enum.filter(&owned_by?(&1, owner))
      |> Enum.flat_map(&safe_parse_rrsig(&1.rdata))
      |> Enum.filter(&(&1.type_covered == type))
      |> Enum.any?(&rrsig_validates?(&1, [rr], parent_keys, now))
    end)
  end

  defp safe_parse_rrsig(rdata) do
    [RR.parse_rrsig(rdata)]
  rescue
    _ -> []
  end

  defp verify_answer(rrsigs, rrset, trusted_keys, signer, now) do
    if Enum.any?(rrsigs, &rrsig_validates?(&1, rrset, trusted_keys, now)) do
      {:secure, Wire.name_to_string(signer)}
    else
      {:bogus, :answer_signature_invalid}
    end
  end

  defp rrsig_validates?(%RRSIG{} = rrsig, rrset, trusted_keys, now) do
    key = Enum.find(trusted_keys, &(RR.key_tag(&1) == rrsig.key_tag))
    key && within?(rrsig, now) && Crypto.verify_rrsig(rrsig, rrset, key)
  end

  # --- helpers ---

  defp parse_dnskeys(msg),
    do: msg |> Wire.records_of_type(@dnskey) |> Enum.map(&RR.parse_dnskey(&1.rdata))

  # Parse every RRSIG in the message, skipping malformed records (an injected junk RRSIG
  # must not raise the whole validation into a bogus verdict).
  defp rrsigs(msg),
    do: msg |> Wire.records_of_type(@rrsig) |> Enum.flat_map(&safe_parse_rrsig(&1.rdata))

  # The RRSIG + RRset owned by `qname_labels` covering `qtype`; falls back to a signed
  # CNAME at the same name (a common indirection for A/AAAA queries).
  defp answer_rrsig(msg, qname_labels, qtype) do
    signed_rrset(msg, qname_labels, qtype) || signed_rrset(msg, qname_labels, 5)
  end

  defp signed_rrset(msg, qname_labels, type) do
    rrset =
      msg |> Wire.records_of_type(type) |> Enum.filter(&owned_by?(&1, qname_labels))

    rrsigs =
      msg
      |> Wire.records_of_type(@rrsig)
      |> Enum.filter(&owned_by?(&1, qname_labels))
      |> Enum.flat_map(&safe_parse_rrsig(&1.rdata))
      |> Enum.filter(&(&1.type_covered == type))

    if rrsigs != [] and rrset != [], do: {rrsigs, rrset}
  end

  defp owned_by?(%Wire.RR{name: name}, qname_labels),
    do: Enum.map(name, &String.downcase/1) == qname_labels

  defp name_labels(qname) do
    case String.trim_trailing(qname, ".") do
      "" -> []
      s -> s |> String.split(".") |> Enum.map(&String.downcase/1)
    end
  end

  # RRSIG validity period (RFC 4034 §3.1.5). Plain comparison (no serial-number wrap).
  defp within?(%RRSIG{inception: inc, expiration: exp}, now), do: inc <= now and now <= exp

  # Zones from root to `signer`, root first. Each entry: {zone_string, label_list, last?}.
  defp ancestors(signer_labels) do
    n = length(signer_labels)

    for i <- 0..n do
      labels = Enum.take(signer_labels, -i)
      {zone_string(labels), labels, i == n}
    end
  end

  defp zone_string([]), do: "."
  defp zone_string(labels), do: Enum.map_join(labels, ".", &String.downcase/1)
end
