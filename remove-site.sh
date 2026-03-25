#!/bin/sh
# remove-site.sh — Remove a Tor hidden service
#
# Usage: ./remove-site.sh <name> [--purge-keys]
#
#   name          The site identifier used when adding (e.g. "myblog")
#   --purge-keys  Also delete the hidden service keys (permanently loses
#                 the .onion address). Without this flag, keys are preserved
#                 in the tor-keys volume so the .onion can be reused later.
#
# After removing, run:
#   docker compose up -d && docker compose restart tor

set -e

NAME=""
PURGE_KEYS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-keys)
      PURGE_KEYS=true
      shift
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
      if [ -z "$NAME" ]; then
        NAME="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Usage: $0 <name> [--purge-keys]"
  echo "  e.g. $0 myblog"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$SCRIPT_DIR/conf.d"
TORRC="$SCRIPT_DIR/torrc"

# ---------------------------------------------------------------------------
# Remove nginx config
# ---------------------------------------------------------------------------
if [ -f "$CONF_DIR/$NAME.conf" ]; then
  rm "$CONF_DIR/$NAME.conf"
  echo "Removed $CONF_DIR/$NAME.conf"
else
  echo "Warning: $CONF_DIR/$NAME.conf not found (already removed?)"
fi

# ---------------------------------------------------------------------------
# Remove torrc block
# ---------------------------------------------------------------------------
# The block looks like:
#   # --- domain.com ---
#   HiddenServiceDir /var/lib/tor/hidden_service/<name>/
#   HiddenServicePort 80 onion-proxy:<port>
#   HiddenServiceVersion 3
#
# We match from a blank line + comment before the HiddenServiceDir through
# the HiddenServiceVersion line.
if grep -q "HiddenServiceDir /var/lib/tor/hidden_service/$NAME/" "$TORRC" 2>/dev/null; then
  # Use sed to remove the block: the comment line, plus the 3 Tor directives
  # Also remove the leading blank line if present
  TMPFILE=$(mktemp)
  awk -v name="$NAME" '
    BEGIN { skip = 0 }
    /^$/ && !skip { blank = $0; next }
    /^# ---/ && !skip {
      # Peek: if next HiddenServiceDir matches our name, start skipping
      comment = $0
      if (blank != "") pending_blank = blank
      blank = ""
      getline
      if ($0 ~ "HiddenServiceDir /var/lib/tor/hidden_service/" name "/") {
        skip = 3  # skip this line + next 2 (HiddenServicePort, HiddenServiceVersion)
        pending_blank = ""
        next
      } else {
        if (pending_blank != "") print pending_blank
        pending_blank = ""
        print comment
        # fall through to print current line
      }
    }
    skip > 0 { skip--; next }
    {
      if (blank != "") { print blank; blank = "" }
      print
    }
    END { if (blank != "") print blank }
  ' "$TORRC" > "$TMPFILE"
  mv "$TMPFILE" "$TORRC"
  echo "Removed $NAME from $TORRC"
else
  echo "Warning: $NAME not found in $TORRC (already removed?)"
fi

# ---------------------------------------------------------------------------
# Optionally purge keys
# ---------------------------------------------------------------------------
if [ "$PURGE_KEYS" = "true" ]; then
  echo ""
  echo "WARNING: This will permanently destroy the .onion address for $NAME."
  printf "Are you sure? [y/N] "
  read -r CONFIRM
  case "$CONFIRM" in
    [yY]|[yY][eE][sS])
      if docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec tor rm -rf "/var/lib/tor/hidden_service/$NAME" 2>/dev/null; then
        echo "Purged hidden service keys for $NAME."
      else
        echo "Could not reach the tor container (is it running?)."
        echo "To purge manually, start the stack and run:"
        echo "  docker compose exec tor rm -rf /var/lib/tor/hidden_service/$NAME"
      fi
      ;;
    *)
      echo "Skipping key purge. Keys preserved in the tor-keys volume."
      ;;
  esac
else
  echo ""
  echo "Hidden service keys preserved in the tor-keys volume."
  echo "The .onion address can be reused if you re-add $NAME later."
fi

echo ""
echo "Now run:"
echo "  docker compose up -d          # picks up nginx config removal"
echo "  docker compose restart tor     # picks up torrc changes"
