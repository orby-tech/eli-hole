defmodule EliHole.DNSSEC.TrustAnchor do
  @moduledoc """
  The ICANN root zone trust anchors, hardcoded as DS records (IANA root-anchors.xml).

  As of 2026 a KSK rollover is in progress and TWO anchors are published and valid —
  both are pinned here. Anchoring only KSK-2017 would break validation during the
  Oct-2026…Jan-2027 window when KSK-2024 takes over signing.

  Re-check at <https://data.iana.org/root-anchors/root-anchors.xml> when KSK-2017 is
  revoked (scheduled 2027-01-11).
  """

  alias EliHole.DNSSEC.RR.DS

  @anchors [
    # KSK-2017
    %DS{
      key_tag: 20326,
      algorithm: 8,
      digest_type: 2,
      digest: Base.decode16!("E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D")
    },
    # KSK-2024
    %DS{
      key_tag: 38696,
      algorithm: 8,
      digest_type: 2,
      digest: Base.decode16!("683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16")
    }
  ]

  @doc "All published root DS trust anchors."
  def root_ds, do: @anchors

  @doc "Root DS anchors matching a given key tag (usually 0 or 1 entry)."
  def root_ds(key_tag) when is_integer(key_tag),
    do: Enum.filter(@anchors, &(&1.key_tag == key_tag))
end
