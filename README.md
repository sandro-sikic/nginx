# nginx — runtime env var substitution for config directory

A lightweight custom entrypoint that injects environment variables into your Nginx configuration at container start. Mount a folder of `.conf` templates, define your variables in Docker Compose (or `docker run`), and the entrypoint handles the rest.

---

## Usage

### Quick start — Docker Compose

```yaml
services:
  nginx:
    image: ghcr.io/sandro-sikic/nginx:latest
    environment:
      - DOMAIN=test.com
      - domain2=example.com
    volumes:
      - ./conf.d:/conf.d
```

---

## How it works

On every container start the entrypoint runs three steps in order:

1. **Copy config dir** — copies everything from `/conf.d` (your mounted folder) into `/etc/nginx/conf.d`, replacing whatever was there before.
2. **Normalise placeholder casing** — scans every file for `${placeholders}` and uppercases the variable name in place, so `${domain}` becomes `${DOMAIN}`. This means env var names in your config files are case-insensitive.
3. **Substitute values** — replaces every `${VAR}` placeholder with the matching environment variable value. Only the braced `${VAR}` form is substituted; unbraced `$VAR` references (e.g. nginx variables like `$host`) are intentionally left untouched.

All output is written to stderr with UTC timestamps and a log level (`INFO` / `WARN` / `ERROR`).

---

## Writing config templates

Use the braced `${VAR}` syntax for values you want substituted. Variable names are case-insensitive — `${domain}`, `${Domain}`, and `${DOMAIN}` all resolve to the same env var.

Use bare `$var` (no braces) for native nginx variables — they are never touched by the entrypoint.

Example (`conf.d/production.conf`):

```nginx
resolver 127.0.0.11 valid=10s;

server {
  listen 80;
  server_name ${DOMAIN} www.${DOMAIN2};

  location / {
    set $app "http://app:3000";   # $app is an nginx variable — left untouched
    proxy_pass $app;
  }

  location /websocket/ {
    set $app "http://app:3000";
    proxy_pass $app;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400;
  }
}
```

After substitution with `DOMAIN=example.com` and `DOMAIN2=other.com`:

```nginx
  server_name example.com www.other.com;
```

---

## Adding it to another service

This image is designed to sit in front of an app behind a shared reverse proxy that handles public traffic and TLS (an [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) container with the [acme-companion](https://github.com/nginx-proxy/acme-companion) for Let's Encrypt). Each service ships its own nginx container that joins the proxy's network.

### 1. Create the shared network (once per host)

The proxy and every service's nginx container must share an external Docker network:

```bash
docker network create proxy_network
```

### 2. Define the domain in an env file

Put the domain in the service's `.env` (Compose reads it automatically):

```env
DOMAIN=app.example.com
```

### 3. Add the nginx service to the service's `docker-compose.yml`

```yaml
services:
  nginx:
    image: ghcr.io/sandro-sikic/nginx:latest
    environment:
      - DOMAIN=${DOMAIN}
      - VIRTUAL_HOST=${DOMAIN}
      - LETSENCRYPT_HOST=${DOMAIN}
    volumes:
      - ./conf.d:/conf.d
    depends_on:
      - app
    networks:
      - default
      - proxy_network

networks:
  proxy_network:
    external: true
```

- `DOMAIN` is substituted into your `conf.d` templates by this image.
- `VIRTUAL_HOST` tells nginx-proxy which domain to route to this container.
- `LETSENCRYPT_HOST` tells acme-companion to issue a certificate for that domain.
- Joining both `default` and `proxy_network` lets nginx reach your app on the service's own network while staying reachable by the proxy. Keep the app and database on `default` only so they are not exposed to the proxy network.
- Do not publish port `80` on this container; the shared proxy is the only public entry point.

### 4. Add a template in `conf.d/`

Point `proxy_pass` at the app's Compose service name and internal port:

```nginx
server {
  listen 80;
  server_name ${DOMAIN};

  resolver 127.0.0.11 valid=10s;
  set $app http://app:3000;

  location / {
    proxy_pass $app;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
```

Replace `app` and `3000` with your service name and port. Then run `docker compose up -d`. A complete working example is [sandro-sikic/analytics](https://github.com/sandro-sikic/analytics) (Umami behind this image).

---

## Notes & caveats ⚠️

- Only `${VAR}` (braced) placeholders are substituted. Bare `$VAR` is never modified — this is intentional so nginx variables like `$host`, `$uri`, and `$http_upgrade` are preserved.
- Variable names in templates are normalised to uppercase before substitution, so env var casing in Docker Compose does not matter.
- If an env var is not set, its placeholder is left as-is in the rendered config (no silent empty-string replacement).
- The `/conf.d` copy is destructive — `/etc/nginx/conf.d` is wiped and replaced on every start.

---

## Troubleshooting

- Check container logs for `Copying`, `Normalizing`, `Processing file:`, and `Applied substitutions` messages.
- Verify that your environment variables are actually passed to the container (`docker inspect` or `docker compose config`).

---

## License

MIT
