defmodule EliHole.DNSSEC.ValidatorTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.{Validator, Wire}
  alias EliHole.DNSSECFixtures, as: F

  # The captured RRSIGs are valid around their capture date; pin "now" inside that window
  # so temporal checks are deterministic as the real clock moves past expiration.
  @now DateTime.to_unix(~U[2026-05-29 12:00:00Z])

  defp msg(fixture), do: F.packet(fixture) |> Wire.parse() |> elem(1)

  # A synthetic answer carrying an (unverified) A + RRSIG owned by `labels`. Used to drive
  # the chain walk to a given signer; the chain returns before the answer sig is checked.
  defp fake_signed_answer(labels) do
    signer_wire = Enum.reduce(labels, <<>>, &(&2 <> <<byte_size(&1)>> <> &1)) <> <<0>>

    rrsig_rdata =
      <<1::16, 13, length(labels), 300::32, 0::32, 0::32, 1234::16>> <> signer_wire <> <<0::512>>

    %Wire.Message{
      rcode: 0,
      answers: [
        %Wire.RR{name: labels, type: 1, class: 1, ttl: 300, rdata: <<1, 2, 3, 4>>},
        %Wire.RR{name: labels, type: 46, class: 1, ttl: 300, rdata: rrsig_rdata}
      ]
    }
  end

  # Flip a byte in every RRSIG that covers NSEC (type 47), invalidating the denial proof.
  defp tamper_nsec_rrsigs(%Wire.Message{} = msg) do
    bust = fn rrs ->
      Enum.map(rrs, fn rr ->
        if rr.type == 46 and match?(<<47::16, _::binary>>, rr.rdata) do
          <<a, b, rest::binary>> = rr.rdata
          %{rr | rdata: <<a, Bitwise.bxor(b, 1), rest::binary>>}
        else
          rr
        end
      end)
    end

    %{msg | answers: bust.(msg.answers), authority: bust.(msg.authority)}
  end

  # The denial fixtures were captured a day later; pin a "now" inside the intersection of
  # all their (and their chains') RRSIG validity windows.
  @denial_now DateTime.to_unix(~U[2026-05-30 12:00:00Z])

  defp nl_fetch do
    fn
      ".", 48 -> {:ok, msg(:root_dnskey)}
      "nl", 48 -> {:ok, msg(:nl_dnskey)}
      "nl", 43 -> {:ok, msg(:nl_ds)}
      "nlnetlabs.nl", 48 -> {:ok, msg(:nlnetlabs_dnskey)}
      "nlnetlabs.nl", 43 -> {:ok, msg(:nlnetlabs_ds)}
      other, type -> {:error, {:unexpected_fetch, other, type}}
    end
  end

  # Offline fetcher mapping (zone, type) → captured response, covering root → com → cloudflare.com.
  defp chain_fetch do
    fn
      ".", 48 -> {:ok, msg(:root_dnskey)}
      "com", 48 -> {:ok, msg(:com_dnskey)}
      "com", 43 -> {:ok, msg(:com_ds)}
      "cloudflare.com", 48 -> {:ok, msg(:cloudflare_dnskey)}
      "cloudflare.com", 43 -> {:ok, msg(:cloudflare_ds)}
      other, type -> {:error, {:unexpected_fetch, other, type}}
    end
  end

  describe "validate/4 — secure path" do
    test "full chain root → com → cloudflare.com validates an A answer as SECURE" do
      answer = msg(:cloudflare_a)

      assert {:secure, "cloudflare.com"} =
               Validator.validate("cloudflare.com", 1, answer, fetch: chain_fetch(), now: @now)
    end
  end

  describe "validate/4 — bogus paths" do
    test "a tampered answer RRset is BOGUS" do
      answer = msg(:cloudflare_a)

      tampered = %{
        answer
        | answers:
            Enum.map(answer.answers, fn rr ->
              if rr.type == 1 do
                <<b, tail::binary>> = rr.rdata
                %{rr | rdata: <<Bitwise.bxor(b, 1), tail::binary>>}
              else
                rr
              end
            end)
      }

      assert {:bogus, _} =
               Validator.validate("cloudflare.com", 1, tampered, fetch: chain_fetch(), now: @now)
    end

    test "an expired signature (validating far in the future) is BOGUS" do
      future = DateTime.to_unix(~U[2099-01-01 00:00:00Z])
      answer = msg(:cloudflare_a)

      assert {:bogus, _} =
               Validator.validate("cloudflare.com", 1, answer, fetch: chain_fetch(), now: future)
    end

    test "a broken delegation (DS that matches no DNSKEY) is BOGUS" do
      # Serve the WRONG DNSKEY set for cloudflare.com (com's keys) so no key matches the DS.
      fetch = fn
        "cloudflare.com", 48 -> {:ok, msg(:com_dnskey)}
        zone, type -> chain_fetch().(zone, type)
      end

      answer = msg(:cloudflare_a)

      assert {:bogus, _} =
               Validator.validate("cloudflare.com", 1, answer, fetch: fetch, now: @now)
    end
  end

  describe "validate/4 — insecure paths" do
    test "a signed RRset owned by a DIFFERENT name is NOT reported secure" do
      # The answer validly signs cloudflare.com, but the query was for another name.
      # Owner-name binding must prevent a {:secure, "cloudflare.com"} verdict here.
      answer = msg(:cloudflare_a)

      assert {:insecure, :no_rrsig_in_answer} =
               Validator.validate("evil.example", 1, answer, fetch: chain_fetch(), now: @now)
    end

    test "an absent DS proven by an NSEC3 opt-out chain is INSECURE (not a downgrade)" do
      # microsoft.com is an unsigned delegation under .com (NSEC3 opt-out). The chain walks
      # root → com → microsoft.com; the empty DS must be backed by the signed NSEC3 proof.
      fetch = fn
        ".", 48 -> {:ok, msg(:root_dnskey)}
        "com", 48 -> {:ok, msg(:com_dnskey)}
        "com", 43 -> {:ok, msg(:com_ds)}
        "microsoft.com", 43 -> {:ok, msg(:ds_nodata_optout)}
        other, type -> {:error, {:unexpected_fetch, other, type}}
      end

      answer = fake_signed_answer(["microsoft", "com"])

      assert {:insecure, {:no_ds_optout, "microsoft.com"}} =
               Validator.validate("microsoft.com", 1, answer, fetch: fetch, now: @now)
    end

    test "an absent DS with NO authenticated denial is a downgrade → BOGUS" do
      # Same path, but the parent's NSEC3 proof is stripped → cannot prove DS absence.
      fetch = fn
        ".", 48 -> {:ok, msg(:root_dnskey)}
        "com", 48 -> {:ok, msg(:com_dnskey)}
        "com", 43 -> {:ok, msg(:com_ds)}
        "microsoft.com", 43 -> {:ok, %Wire.Message{rcode: 0, answers: [], authority: []}}
        other, type -> {:error, {:unexpected_fetch, other, type}}
      end

      answer = fake_signed_answer(["microsoft", "com"])

      assert {:bogus, {:ds_denial_missing, "microsoft.com"}} =
               Validator.validate("microsoft.com", 1, answer, fetch: fetch, now: @now)
    end
  end

  describe "validate/4 — authenticated denial of existence" do
    test "NSEC black-lies NXDOMAIN (cloudflare.com) is SECURE" do
      assert {:secure, "cloudflare.com"} =
               Validator.validate(
                 "nope-zzz999.cloudflare.com",
                 1,
                 msg(:cloudflare_nxdomain),
                 fetch: chain_fetch(),
                 now: @denial_now
               )
    end

    test "NSEC NODATA (cloudflare.com TLSA) is SECURE" do
      assert {:secure, "cloudflare.com"} =
               Validator.validate("cloudflare.com", 52, msg(:cloudflare_nodata),
                 fetch: chain_fetch(),
                 now: @denial_now
               )
    end

    test "classic NSEC NXDOMAIN cover (nlnetlabs.nl) is SECURE" do
      assert {:secure, "nlnetlabs.nl"} =
               Validator.validate(
                 "doesnotexist-zzz999.nlnetlabs.nl",
                 1,
                 msg(:nlnetlabs_nxdomain),
                 fetch: nl_fetch(),
                 now: @denial_now
               )
    end

    test "classic NSEC NODATA (nlnetlabs.nl) is SECURE" do
      assert {:secure, "nlnetlabs.nl"} =
               Validator.validate("nlnetlabs.nl", 99, msg(:nlnetlabs_nodata),
                 fetch: nl_fetch(),
                 now: @denial_now
               )
    end

    test "a junk RRSIG injected into a valid denial does not turn it BOGUS" do
      # A man-in-the-path appends a malformed RRSIG; the real proof must still validate and
      # the denial path must never raise into a bogus SERVFAIL.
      base = msg(:cloudflare_nodata)

      junk = %Wire.RR{
        name: ["cloudflare", "com"],
        type: 46,
        class: 1,
        ttl: 60,
        rdata: <<47::16, 255>>
      }

      poisoned = %{base | authority: [junk | base.authority], answers: [junk | base.answers]}

      assert {:secure, "cloudflare.com"} =
               Validator.validate("cloudflare.com", 52, poisoned,
                 fetch: chain_fetch(),
                 now: @denial_now
               )
    end

    test "a denial whose NSEC signature is broken falls back to INSECURE (never bogus)" do
      # Corrupt every NSEC RRSIG so signed_denials rejects them → proof cannot be trusted.
      tampered = tamper_nsec_rrsigs(msg(:cloudflare_nxdomain))

      assert {:insecure, _} =
               Validator.validate("nope-zzz999.cloudflare.com", 1, tampered,
                 fetch: chain_fetch(),
                 now: @denial_now
               )
    end
  end

  describe "legacy no-RRSIG" do
    test "an answer with no RRSIG and no SOA is INSECURE" do
      unsigned = %Wire.Message{
        rcode: 0,
        answers: [
          %Wire.RR{name: ["plain", "example"], type: 1, class: 1, ttl: 60, rdata: <<1, 2, 3, 4>>}
        ]
      }

      assert {:insecure, :no_rrsig_in_answer} =
               Validator.validate("plain.example", 1, unsigned, fetch: chain_fetch(), now: @now)
    end
  end
end
