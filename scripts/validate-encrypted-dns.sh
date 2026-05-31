#!/usr/bin/env bash
# Manual smoke test for DNS-over-TLS (RFC 7858) and DNS-over-HTTPS (RFC 8484).
#
# Both transports route through the same EliHole.DNS.Handler as plain UDP, so a
# pass here proves blocking/cache/DNSSEC apply identically over encrypted paths.
#
# Env overrides:
#   PHX_PORT  (default 4410)  — web port hosting the DoH /dns-query endpoint
#   PHX_SCHEME(default http)  — http when TLS terminates upstream; https otherwise
#   DOT_PORT  (default 8853)  — DoT listener port
#   DOT_HOST  (default 127.0.0.1)
#   DOMAIN    (default example.com)      — a resolvable name
#   BLOCKED   (default doubleclick.net)  — a name expected on the blocklist
#
# Requires: kdig (knot-dnsutils), curl, python3.
set -uo pipefail

PHX_PORT="${PHX_PORT:-4410}"
PHX_SCHEME="${PHX_SCHEME:-http}"
DOT_PORT="${DOT_PORT:-8853}"
DOT_HOST="${DOT_HOST:-127.0.0.1}"
DOMAIN="${DOMAIN:-example.com}"
BLOCKED="${BLOCKED:-doubleclick.net}"
DOH_URL="${PHX_SCHEME}://127.0.0.1:${PHX_PORT}/dns-query"

pass=0
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 127; }; }

need curl
need python3

# Build a minimal wire-format query (id=0x1234, RD=1, one A/IN question).
# Prints raw bytes to stdout. Arg: domain.
build_query() {
  python3 - "$1" <<'PY'
import struct, sys
name = sys.argv[1]
hdr = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
q = b"".join(bytes([len(l)]) + l.encode() for l in name.split(".")) + b"\x00"
q += struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN
sys.stdout.buffer.write(hdr + q)
PY
}

# Decode a wire-format DNS response file: print "RCODE=<n> ANCOUNT=<n> A=<ip|->".
# Arg: path to the response binary. (Reads from a file, not stdin, because the
# heredoc already occupies python's stdin as the script source.)
decode_response() {
  python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 12:
    print("RCODE=? ANCOUNT=0 A=- (short)"); sys.exit()
flags, qd, an = struct.unpack(">HHH", d[2:8])
rcode = flags & 0xF
# skip header + question section to find first A rdata
off = 12
for _ in range(qd):
    while d[off] != 0:
        off += d[off] + 1
    off += 5  # null label + QTYPE + QCLASS
ip = "-"
for _ in range(an):
    # name (may be compressed pointer)
    if d[off] & 0xC0 == 0xC0:
        off += 2
    else:
        while d[off] != 0:
            off += d[off] + 1
        off += 1
    rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", d[off:off+10])
    off += 10
    if rtype == 1 and rdlen == 4:
        ip = ".".join(str(b) for b in d[off:off+4])
        break
    off += rdlen
print(f"RCODE={rcode} ANCOUNT={an} A={ip}")
PY
}

echo "EliHole encrypted-DNS smoke test"
echo "  DoH: ${DOH_URL}"
echo "  DoT: ${DOT_HOST}:${DOT_PORT}"
echo

# ----------------------------------------------------------------------------
echo "DoH (RFC 8484)"

q=$(build_query "$DOMAIN" | base64 -w0 | tr '+/' '-_' | tr -d '=')
get=$(curl -sk -o /tmp/doh_get.bin -w '%{http_code}' "${DOH_URL}?dns=${q}")
if [ "$get" = "200" ] && [ -s /tmp/doh_get.bin ]; then
  ok "GET ?dns= → 200 ($(decode_response /tmp/doh_get.bin))"
else
  bad "GET ?dns= → HTTP $get"
fi

build_query "$DOMAIN" > /tmp/doh_q.bin
post=$(curl -sk -o /tmp/doh_post.bin -w '%{http_code}' -X POST "$DOH_URL" \
  -H 'content-type: application/dns-message' --data-binary @/tmp/doh_q.bin)
if [ "$post" = "200" ] && [ -s /tmp/doh_post.bin ]; then
  ok "POST body → 200 ($(decode_response /tmp/doh_post.bin))"
else
  bad "POST body → HTTP $post"
fi

# blocked domain still blocked over DoH
qb=$(build_query "$BLOCKED" | base64 -w0 | tr '+/' '-_' | tr -d '=')
curl -sk -o /tmp/doh_blk.bin "${DOH_URL}?dns=${qb}"
blk=$(decode_response /tmp/doh_blk.bin)
case "$blk" in
  *"A=0.0.0.0"*|*"RCODE=3"*) ok "blocked $BLOCKED over DoH ($blk)" ;;
  *)                          bad "blocked $BLOCKED NOT blocked ($blk)" ;;
esac

# negative cases
n1=$(curl -sk -o /dev/null -w '%{http_code}' "$DOH_URL")
[ "$n1" = "400" ] && ok "no dns param → 400" || bad "no dns param → $n1 (want 400)"
n2=$(curl -sk -o /dev/null -w '%{http_code}' "${DOH_URL}?dns=@@@bad")
[ "$n2" = "400" ] && ok "bad base64 → 400" || bad "bad base64 → $n2 (want 400)"

echo
# ----------------------------------------------------------------------------
echo "DoT (RFC 7858)"

if ! command -v kdig >/dev/null 2>&1; then
  echo "  (skipped: kdig not installed — apt install knot-dnsutils)"
else
  out=$(kdig +tls +timeout=5 -p "$DOT_PORT" "@${DOT_HOST}" "$DOMAIN" 2>&1)
  if echo "$out" | grep -q "status: NOERROR"; then
    ok "$DOMAIN over DoT → NOERROR"
  else
    bad "$DOMAIN over DoT failed"; echo "$out" | sed 's/^/      /'
  fi

  outb=$(kdig +tls +timeout=5 -p "$DOT_PORT" "@${DOT_HOST}" "$BLOCKED" 2>&1)
  if echo "$outb" | grep -qE "0\.0\.0\.0|status: NXDOMAIN"; then
    ok "blocked $BLOCKED over DoT"
  else
    bad "blocked $BLOCKED NOT blocked over DoT"; echo "$outb" | sed 's/^/      /'
  fi
fi

echo
echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
