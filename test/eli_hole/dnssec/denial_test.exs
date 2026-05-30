defmodule EliHole.DNSSEC.DenialTest do
  use ExUnit.Case, async: true

  alias EliHole.DNSSEC.Denial

  # RFC 5155 Appendix A — zone "example", salt aabbccdd, 12 iterations, SHA-1.
  @salt <<0xAA, 0xBB, 0xCC, 0xDD>>

  defp b32(bin), do: Base.hex_encode32(bin, case: :lower, padding: false)

  describe "nsec3_hash/3 (RFC 5155 test vectors)" do
    test "matches the published hashed owner names" do
      assert b32(Denial.nsec3_hash(["example"], @salt, 12)) == "0p9mhaveqvm6t7vbl5lop2u3t2rp3tom"

      assert b32(Denial.nsec3_hash(["a", "example"], @salt, 12)) ==
               "35mthgpgcu1qg68fab165klnsnk3dpvl"

      assert b32(Denial.nsec3_hash(["ns1", "example"], @salt, 12)) ==
               "2t7b4g4vsa5smi47k61mv5bv1a22bojr"
    end

    test "is case-insensitive on the owner name (canonical lower-casing)" do
      assert Denial.nsec3_hash(["EXAMPLE"], @salt, 12) ==
               Denial.nsec3_hash(["example"], @salt, 12)
    end

    test "iteration count changes the hash" do
      refute Denial.nsec3_hash(["example"], @salt, 12) == Denial.nsec3_hash(["example"], @salt, 0)
    end
  end
end
