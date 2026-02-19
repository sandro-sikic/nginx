#!/usr/bin/env sh
set -eu

# --- logging helpers -------------------------------------------------------
log() {
  level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}
info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }

info "Entrypoint started"

# Copy contents of /conf.d into /etc/nginx/conf.d, overwriting existing files.
copy_config_dir() {
  if [ -d /conf.d ]; then
    files_found=$(find /conf.d -type f 2>/dev/null | wc -l | tr -d ' ')
    info "Copying ${files_found:-0} file(s) from /conf.d to /etc/nginx/conf.d"

    # remove destination to ensure a clean copy
    if [ -d /etc/nginx/conf.d ]; then
      info "Removing existing /etc/nginx/conf.d"
      rm -rf /etc/nginx/conf.d
      info "Removed /etc/nginx/conf.d"
    fi

    mkdir -p /etc/nginx/conf.d

    if cp -R /conf.d/. /etc/nginx/conf.d/; then
      info "Copy complete"
    else
      error "Failed to copy /conf.d to /etc/nginx/conf.d"
      return 1
    fi
  else
    info "/conf.d not present; skipping copy"
  fi
}

# Normalize placeholders to UPPERCASE (so $Domain or ${domain} -> $DOMAIN)
normalize_placeholders_to_uppercase() {
  if [ ! -d /etc/nginx/conf.d ]; then
    info "No configs to normalize; skipping placeholder normalization"
    return 0
  fi

  info "Normalizing env placeholder names to UPPERCASE in /etc/nginx/conf.d"

  for f in /etc/nginx/conf.d/*; do
    [ -f "$f" ] || continue

    # find braced placeholders ${var} only
    for ph in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$f" 2>/dev/null | sort -u || true); do
      name=$(printf '%s' "$ph" | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/\1/')
      upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
      [ "$name" = "$upper" ] && continue

      # replace braced form ${name} -> ${UPPER}
      sed -i 's/\${'"$name"'}/\${'"$upper"'}/g' "$f" || true
    done
  done

  info "Placeholder normalization complete"
}

# Substitute all ${VAR} (braced) placeholders in every file in /etc/nginx/conf.d.
# Unbraced $VAR references are intentionally left untouched.
substitute_placeholders() {
  if [ ! -d /etc/nginx/conf.d ]; then
    info "/etc/nginx/conf.d missing; skipping substitution"
    return 0
  fi

  info "Starting substitution pass over /etc/nginx/conf.d"

  # Build a sed script once: one s|${VAR}|value|g line per env var.
  # Using | as delimiter; escape |, &, and \ in values to keep sed happy.
  sedscript=$(mktemp)
  env | while IFS='=' read -r var val; do
    [ -n "$var" ] || continue
    upper=$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')
    esc_val=$(printf '%s' "$val" | sed 's/[|&\]/\\&/g')
    printf 's|\\${%s}|%s|g\n' "$upper" "$esc_val"
  done > "$sedscript"

  for f in /etc/nginx/conf.d/*; do
    [ -f "$f" ] || continue
    info "Processing file: $f"
    tmp="${f}.tmp"

    if sed -f "$sedscript" "$f" > "$tmp"; then
      if ! cmp -s "$tmp" "$f" 2>/dev/null; then
        mv "$tmp" "$f"
        info "Applied substitutions -> $f"
      else
        rm -f "$tmp"
      fi
    else
      rm -f "$tmp"
      warn "sed substitution failed on $f"
    fi
  done

  rm -f "$sedscript"
  info "Substitution pass complete"
}

# Run tasks then exec the container command
copy_config_dir
normalize_placeholders_to_uppercase
substitute_placeholders

info "Starting main process: $*"
exec "$@"