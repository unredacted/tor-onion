#!/bin/sh
# generate-vanity.sh — Generate a vanity .onion address using mkp224o
#
# Usage: ./generate-vanity.sh <prefix> [--threads N] [--count N]
#
#   prefix    Desired .onion prefix (a-z, 2-7 only — base32 encoding)
#   --threads Number of CPU threads (default: all available)
#   --count   Number of matching addresses to generate (default: 1)
#
# Examples:
#   ./generate-vanity.sh mysite
#   ./generate-vanity.sh unredact --threads 4
#   ./generate-vanity.sh cool --count 5
#
# Time estimates (approximate, varies by hardware):
#   4 chars:  seconds
#   5 chars:  seconds to minutes
#   6 chars:  minutes to tens of minutes
#   7 chars:  hours to days
#   8+ chars: impractical
#
# Output is saved to vanity-keys/<address>.onion/
# These directories contain private keys — treat them like SSH keys.

set -e

MKPIMAGE="ghcr.io/cathugger/mkp224o:master"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PREFIX=""
THREADS=""
COUNT="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --threads)
      THREADS="$2"
      shift 2
      ;;
    --count)
      COUNT="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^$/s/^# \?//p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$PREFIX" ]; then
        PREFIX="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$PREFIX" ]; then
  echo "Usage: $0 <prefix> [--threads N] [--count N]"
  echo "  e.g. $0 mysite"
  echo "  e.g. $0 unredact --threads 4 --count 3"
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate prefix — base32 only (a-z, 2-7)
# ---------------------------------------------------------------------------
if echo "$PREFIX" | grep -qE '[^a-z2-7]'; then
  echo "Error: prefix must contain only base32 characters (a-z, 2-7)" >&2
  echo "  .onion addresses cannot contain: 0, 1, 8, 9, or uppercase" >&2
  exit 1
fi

# Warn about long prefixes
PREFIX_LEN=$(printf '%s' "$PREFIX" | wc -c | tr -d ' ')
if [ "$PREFIX_LEN" -ge 8 ]; then
  echo "WARNING: An ${PREFIX_LEN}-character prefix may take weeks or longer." >&2
  echo "Consider using a shorter prefix (6-7 chars max)." >&2
  printf "Continue anyway? [y/N] " >&2
  read -r CONFIRM
  case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
elif [ "$PREFIX_LEN" -ge 7 ]; then
  echo "Note: a ${PREFIX_LEN}-character prefix may take hours to days."
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/vanity-keys"
mkdir -p "$OUTPUT_DIR"

echo "Generating vanity .onion address with prefix: $PREFIX"
echo "  Count:   $COUNT"
[ -n "$THREADS" ] && echo "  Threads: $THREADS"
echo "  Output:  $OUTPUT_DIR/"
echo ""
echo "This may take a while depending on prefix length..."
echo ""

# ---------------------------------------------------------------------------
# Build docker run command
# ---------------------------------------------------------------------------
DOCKER_ARGS="--rm -v $OUTPUT_DIR:/keys"

# mkp224o args
MKP_ARGS="-d /keys -n $COUNT"
[ -n "$THREADS" ] && MKP_ARGS="$MKP_ARGS -j $THREADS"

# Enable statistics output
MKP_ARGS="$MKP_ARGS -s"

docker run $DOCKER_ARGS "$MKPIMAGE" $MKP_ARGS "$PREFIX"

echo ""
echo "Done! Generated addresses:"
echo ""

# List generated addresses
for dir in "$OUTPUT_DIR"/"$PREFIX"*.onion; do
  if [ -d "$dir" ]; then
    ADDR=$(cat "$dir/hostname" 2>/dev/null || basename "$dir")
    echo "  $ADDR"
  fi
done

echo ""
echo "Key files are in: $OUTPUT_DIR/"
echo ""
echo "To use a vanity address with add-site.sh:"
echo "  ./add-site.sh <name> <domain> --keys $OUTPUT_DIR/<address>.onion"
echo ""
echo "WARNING: These directories contain private keys."
echo "  Treat them like SSH keys — do not share or commit to git."
