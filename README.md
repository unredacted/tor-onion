# Tor Hidden Service Gateway

Expose any clearnet website as a Tor `.onion` hidden service. Uses Nginx [`sub_filter`](https://nginx.org/en/docs/http/ngx_http_sub_module.html) to rewrite clearnet URLs to `.onion` in response bodies — the origin application requires **zero modifications**.

## Architecture

```
Tor visitor → Tor network → tor container → onion-proxy (nginx sub_filter)
                                                ↓
                                          your origin server
```

- **tor** — Alpine container running the `tor` daemon, one `.onion` address per site
- **onion-proxy** — Nginx container with one server block per site. Forwards requests to your origin with the clearnet `Host` header, then rewrites all clearnet URLs to `.onion` in the response body

## How it works

The core trick is two-fold:

1. **`proxy_set_header Host domain.com`** — your origin sees the clearnet hostname and generates its normal URLs
2. **`sub_filter`** — Nginx does a string replacement on the response body, converting `https://domain.com` → `http://your-onion-address.onion` before it reaches the Tor visitor

This means the origin application (WordPress, Ghost, a static site, anything) has no idea Tor exists. No plugins, no config changes, no cache-busting.

## Quick start

```bash
git clone https://github.com/unredacted/tor-onion.git
cd tor-onion

# Add a site — generates nginx config + torrc entry
./add-site.sh mysite example.com

# Start everything
docker compose up -d

# Wait ~30s for Tor to bootstrap, then grab your .onion address
docker compose exec tor cat /var/lib/tor/hidden_service/mysite/hostname
```

Visit the `.onion` address in [Tor Browser](https://www.torproject.org/download/) — all links and assets should point to the `.onion`, not the clearnet.

## Origin modes

The `--origin` flag controls where the onion-proxy forwards requests. There are three common patterns:

### 1. Reverse proxy on the Docker host (default)

Your origin is a reverse proxy (Traefik, Caddy, Nginx, HAProxy, etc.) running on the same machine, listening on the host's port 443.

```bash
./add-site.sh mysite example.com
# Equivalent to:
# ./add-site.sh mysite example.com --origin https://host.docker.internal:443
```

The `host.docker.internal` address lets containers reach the host network. The `extra_hosts` directive in `docker-compose.yml` enables this on Linux.

### 2. Container in the same Docker network

Your origin is another container (e.g., a WordPress or Node.js app).

```bash
./add-site.sh mysite example.com --origin http://wordpress:80
```

You'll also need to connect both stacks to the same Docker network. In `docker-compose.yml`, uncomment the `networks:` sections and set the network name to match your app's network:

```yaml
services:
  onion-proxy:
    networks:
      - my-app-network

networks:
  my-app-network:
    external: true
```

Find your app's network name with `docker network ls`.

### 3. Remote origin server

Your origin is a separate server accessible over the network.

```bash
./add-site.sh mysite example.com --origin https://origin.example.com
```

The onion-proxy will connect to the remote server, set the `Host` header to `example.com`, and rewrite URLs in the response.

## Adding a site

```bash
./add-site.sh <name> <domain> [--origin URL] [--port PORT]
```

This generates:
- `conf.d/<name>.conf` — nginx server block with URL rewriting
- Appends a `HiddenService` block to `torrc`

> **Note:** Generated configs in `conf.d/` are gitignored by default. This keeps deployed configs out of version control. Use `git add -f` if you need to commit one.

Then apply:

```bash
docker compose up -d
docker compose restart tor
docker compose exec tor cat /var/lib/tor/hidden_service/<name>/hostname
```

## Removing a site

```bash
./remove-site.sh <name>
```

This removes the nginx config and the torrc entry. Hidden service keys are **preserved** by default so you can re-add the site later with the same `.onion` address.

To permanently destroy the `.onion` address:

```bash
./remove-site.sh <name> --purge-keys
```

Then apply:

```bash
docker compose up -d
docker compose restart tor
```

## Onion-Location header (optional)

To have Tor Browser suggest your `.onion` to clearnet visitors, add the `Onion-Location` header on your clearnet reverse proxy. For example, in Traefik:

```yaml
http:
  middlewares:
    onion-location:
      headers:
        customResponseHeaders:
          Onion-Location: "http://YOUR_ADDRESS.onion{path}"
```

Or in Nginx:

```nginx
add_header Onion-Location http://YOUR_ADDRESS.onion$request_uri;
```

Or in Caddy:

```
header Onion-Location "http://YOUR_ADDRESS.onion{path}"
```

## Keeping Tor updated

The Tor container is built from `Dockerfile.tor` using Alpine's package repos. To pick up a new Tor release, rebuild the image:

```bash
docker compose build tor && docker compose up -d
```

To track Alpine releases, bump the version in `Dockerfile.tor` (e.g., `FROM alpine:3.22`) and rebuild.

## Backup

The only critical data is the hidden service keys in the `tor-keys` volume:

```bash
docker run --rm -v tor-onion_tor-keys:/data -v $(pwd):/backup alpine \
  tar czf /backup/tor-keys-backup.tar.gz -C /data .
```

## Advanced: WAF integration

If you run a WAF (CrowdSec, ModSecurity, etc.) in front of your origin, you can route Tor traffic through it by pointing `--origin` at the WAF's entrypoint instead of directly at the application. For example, if your WAF is a reverse proxy on the host listening on port 443:

```bash
./add-site.sh mysite example.com --origin https://host.docker.internal:443
```

The request flow becomes:

```
Tor visitor → tor → onion-proxy → WAF (on host) → origin application
```

The WAF sees a normal request with `Host: example.com` and applies its rules identically to clearnet traffic. The URL rewriting still happens at the onion-proxy level on the way back.

## Gotchas

- **Caching**: If your origin has a page cache, it should already key on `Host` header. The onion-proxy sends the clearnet hostname, so WordPress/Varnish/etc. serve from the same cache pool. No special configuration needed.
- **SSL on .onion**: Tor provides end-to-end encryption natively, so `.onion` access is plain HTTP. If your origin forces HTTPS redirects, make sure it only does so based on `X-Forwarded-Proto` (which the onion-proxy sets to `http`).
- **Compressed responses**: The onion-proxy sets `Accept-Encoding: ""` to disable upstream compression so `sub_filter` can work on the raw body. It then re-compresses the response to the client via `gzip on;` in the generated config.
- **`www.` variants**: `sub_filter` does literal string matching. If your origin generates both `https://example.com` and `https://www.example.com`, only the exact domain you specified gets rewritten. Add a second `sub_filter` line to the generated config for the `www.` variant, or set up a redirect from `www.` to the bare domain on your origin.
