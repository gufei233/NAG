#!/bin/sh
set -eu

ENV_FILE="${1:-.env}"
OVERRIDE_FILE="${2:-docker-compose.override.yml}"
MAC_EXAMPLE_FILE="${3:-docker-compose.mac.example.yml}"

generate_mac() {
  if command -v openssl >/dev/null 2>&1; then
    hex="$(openssl rand -hex 5)"
  else
    hex="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  printf '02:%s\n' "$(printf '%s' "$hex" | sed 's/../&:/g; s/:$//')"
}

if [ ! -f "$ENV_FILE" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example."
  else
    touch "$ENV_FILE"
    echo "Created empty $ENV_FILE."
  fi
fi

if grep -Eq '^[[:space:]]*NAPCAT_MAC=' "$ENV_FILE"; then
  current="$(grep -E '^[[:space:]]*NAPCAT_MAC=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
  echo "NAPCAT_MAC already exists in $ENV_FILE: $current"
else
  mac="$(generate_mac)"
  printf '\nNAPCAT_MAC=%s\n' "$mac" >> "$ENV_FILE"
  echo "Generated NAPCAT_MAC in $ENV_FILE: $mac"
fi

if [ -f "$OVERRIDE_FILE" ]; then
  echo "$OVERRIDE_FILE already exists; leaving it unchanged."
elif [ -f "$MAC_EXAMPLE_FILE" ]; then
  cp "$MAC_EXAMPLE_FILE" "$OVERRIDE_FILE"
  echo "Created $OVERRIDE_FILE from $MAC_EXAMPLE_FILE."
else
  echo "Missing $MAC_EXAMPLE_FILE; cannot create $OVERRIDE_FILE." >&2
  exit 1
fi

