#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$unit_dir/opencode-web.service"
port="${OPENCODE_WEB_PORT:-3171}"

bin="$(command -v opencode || true)"
if [[ -z "$bin" ]]; then
    echo "error: opencode was not found in PATH" >&2
    exit 1
fi

if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
    password="$OPENCODE_SERVER_PASSWORD"
elif command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -hex 24)"
else
    password="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
fi

mkdir -p "$unit_dir"
sed \
    -e "s|@BIN@|$bin|g" \
    -e "s|@PORT@|$port|g" \
    -e "s|@PASSWORD@|$password|g" \
    "$here/opencode-web.service.in" > "$unit"
chmod 600 "$unit"

systemctl --user daemon-reload
systemctl --user enable opencode-web.service
systemctl --user restart opencode-web.service

echo "Installed $unit"
echo "OpenCode listens on http://127.0.0.1:$port"
echo "Widget settings: hostname 127.0.0.1, port $port, username opencode, password blank."
