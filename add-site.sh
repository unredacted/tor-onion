#!/bin/sh
# add-site.sh — Add a new Tor hidden service for a clearnet domain
#
# Usage: ./add-site.sh <name> <domain> [--origin URL] [--port PORT]
#
#   name      Short identifier (filenames, torrc dir, e.g. "myblog")
#   domain    Clearnet domain to mirror (e.g. "myblog.com")
#
# Options:
#   --origin URL   Backend to proxy to (default: https://host.docker.internal:443)
#                  Examples:
#                    https://host.docker.internal:443   (reverse proxy on Docker host)
#                    http://myapp:80                    (container in same network)
#                    https://origin.example.com         (remote server)
#   --port PORT    Internal nginx listen port (auto-assigned if omitted)
#
# Examples:
#   ./add-site.sh myblog myblog.com
#   ./add-site.sh wiki wiki.example.org --origin http://mediawiki:80
#   ./add-site.sh shop shop.example.com --origin https://origin.shop.example.com --port 8005

set -e

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
NAME=""
DOMAIN=""
ORIGIN="https://host.docker.internal:443"
PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --origin)
      ORIGIN="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
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
      if [ -z "$NAME" ]; then
        NAME="$1"
      elif [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$NAME" ] || [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <name> <domain> [--origin URL] [--port PORT]"
  echo "  e.g. $0 myblog myblog.com"
  echo "  e.g. $0 wiki wiki.example.org --origin http://mediawiki:80"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$SCRIPT_DIR/conf.d"
TORRC="$SCRIPT_DIR/torrc"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -f "$CONF_DIR/$NAME.conf" ]; then
  echo "Error: $CONF_DIR/$NAME.conf already exists" >&2
  exit 1
fi

if grep -q "HiddenServiceDir /var/lib/tor/hidden_service/$NAME/" "$TORRC" 2>/dev/null; then
  echo "Error: $NAME already exists in torrc" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Auto-assign port: find the highest port in use and increment
# ---------------------------------------------------------------------------
if [ -z "$PORT" ]; then
  HIGHEST=$(grep -h '^[[:space:]]*listen ' "$CONF_DIR"/*.conf 2>/dev/null | awk '{print $2}' | tr -d ';' | sort -n | tail -1)
  if [ -z "$HIGHEST" ]; then
    PORT=8001
  else
    PORT=$((HIGHEST + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Detect origin scheme
# ---------------------------------------------------------------------------
case "$ORIGIN" in
  https://*)
    ORIGIN_IS_TLS=true
    ;;
  http://*)
    ORIGIN_IS_TLS=false
    ;;
  *)
    echo "Error: --origin must start with http:// or https://" >&2
    exit 1
    ;;
esac

echo "Adding site:"
echo "  Name:   $NAME"
echo "  Domain: $DOMAIN"
echo "  Origin: $ORIGIN"
echo "  Port:   $PORT"
echo ""

# ---------------------------------------------------------------------------
# Generate nginx config
# ---------------------------------------------------------------------------
if [ "$ORIGIN_IS_TLS" = "true" ]; then
  cat > "$CONF_DIR/$NAME.conf" <<NGINX_CONF
# $DOMAIN — Tor hidden service rewriting proxy
# Listens on port $PORT (must match HiddenServicePort in torrc)

server {
    listen $PORT;

    # Re-compress responses to the client (upstream compression is disabled
    # so sub_filter can inspect the body)
    gzip on;
    gzip_proxied any;
    gzip_types text/html text/css application/javascript application/json;

    location / {
        proxy_pass $ORIGIN;

        # Origin routes based on this — must be the clearnet domain
        proxy_set_header Host $DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;

        # Disable compression so sub_filter can inspect the body
        proxy_set_header Accept-Encoding "";

        # TLS settings for the upstream connection
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $DOMAIN;

        # Rewrite clearnet URLs to .onion in the response
        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript application/json;
        sub_filter 'https://$DOMAIN' 'http://\$host';
        sub_filter 'http://$DOMAIN'  'http://\$host';
    }
}
NGINX_CONF
else
  cat > "$CONF_DIR/$NAME.conf" <<NGINX_CONF
# $DOMAIN — Tor hidden service rewriting proxy
# Listens on port $PORT (must match HiddenServicePort in torrc)

server {
    listen $PORT;

    # Re-compress responses to the client (upstream compression is disabled
    # so sub_filter can inspect the body)
    gzip on;
    gzip_proxied any;
    gzip_types text/html text/css application/javascript application/json;

    location / {
        proxy_pass $ORIGIN;

        # Origin routes based on this — must be the clearnet domain
        proxy_set_header Host $DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;

        # Disable compression so sub_filter can inspect the body
        proxy_set_header Accept-Encoding "";

        # Rewrite clearnet URLs to .onion in the response
        sub_filter_once off;
        sub_filter_types text/html text/css application/javascript application/json;
        sub_filter 'https://$DOMAIN' 'http://\$host';
        sub_filter 'http://$DOMAIN'  'http://\$host';
    }
}
NGINX_CONF
fi

echo "Created $CONF_DIR/$NAME.conf"

# ---------------------------------------------------------------------------
# Append to torrc
# ---------------------------------------------------------------------------
cat >> "$TORRC" <<EOF

# --- $DOMAIN ---
HiddenServiceDir /var/lib/tor/hidden_service/$NAME/
HiddenServicePort 80 onion-proxy:$PORT
HiddenServiceVersion 3
EOF

echo "Updated $TORRC"
echo ""
echo "Now run:"
echo "  docker compose up -d          # picks up new nginx config"
echo "  docker compose restart tor     # picks up new torrc entry"
echo ""
echo "Then get your .onion address:"
echo "  docker compose exec tor cat /var/lib/tor/hidden_service/$NAME/hostname"
