# nginx — runtime env var substitution for config directory

A lightweight custom entrypoint that injects environment variables into your Nginx configuration at container start. Mount a folder of `.conf` templates, define your variables in Docker Compose (or `docker run`), and the entrypoint handles the rest.

---

## How it works

On every container start the entrypoint runs three steps in order:

1. **Copy config dir** — copies everything from `/conf.d` (your mounted folder) into `/etc/nginx/conf.d`, replacing whatever was there before.
2. **Normalise placeholder casing** — scans every file for `${placeholders}` and uppercases the variable name in place, so `${domain}` becomes `${DOMAIN}`. This means env var names in your config files are case-insensitive.
3. **Substitute values** — replaces every `${VAR}` placeholder with the matching environment variable value. Only the braced `${VAR}` form is substituted; unbraced `$VAR` references (e.g. nginx variables like `$host`) are intentionally left untouched.

All output is written to stderr with UTC timestamps and a log level (`INFO` / `WARN` / `ERROR`).

---

## Repository structure

```
docker-compose.yml   # example compose file
conf.d/              # config templates — mount this as /conf.d inside the container
  production.conf
nginx/
  Dockerfile         # extends the official nginx image
  entrypoint.sh      # the custom entrypoint
  README.md          # this file
```

---

## Quick start — Docker Compose

```yaml
services:
  nginx:
    build: ./nginx
    environment:
      - DOMAIN=example.com
      - DOMAIN2=other.com
    volumes:
      - ./conf.d:/conf.d
```

```bash
docker compose up --build
```

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

## CLI usage

Build:

```bash
docker build -t my-nginx:latest ./nginx
```

Run:

```bash
docker run --rm \
  -e DOMAIN=example.com \
  -e DOMAIN2=other.com \
  -v "$(pwd)/conf.d:/conf.d" \
  -p 80:80 \
  my-nginx:latest
```

(Windows PowerShell: replace `$(pwd)` with `${PWD}`)

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
