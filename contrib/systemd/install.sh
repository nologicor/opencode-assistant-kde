#!/usr/bin/env bash
set -euo pipefail

umask 077

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$unit_dir/opencode-web.service"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-assistant-kde"
auth_file="$data_dir/curl-auth.conf"
port="${OPENCODE_WEB_PORT:-3171}"

bin="$(command -v opencode || true)"
if [[ -z "$bin" ]]; then
    echo "error: opencode was not found in PATH" >&2
    exit 1
fi

if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    echo "error: OPENCODE_WEB_PORT must be a number between 1024 and 65535" >&2
    exit 1
fi

if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
    password="$OPENCODE_SERVER_PASSWORD"
elif command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -hex 24)"
else
    password="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
fi

if [[ ! "$password" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    echo "error: the password may only contain letters, digits, dot, underscore, tilde, and hyphen" >&2
    exit 1
fi

mkdir -p "$unit_dir" "$data_dir"
chmod 700 "$data_dir"
install -m 600 /dev/null "$unit"
install -m 600 /dev/null "$auth_file"

# Generate the unit from the template. The password is passed in awk's
# environment, not in its argv, and the replacement does not interpret & or \.
BIN="$bin" PORT="$port" PASSWORD="$password" awk '
    function replace(line, key, value, i) {
        while ((i = index(line, key)) > 0)
            line = substr(line, 1, i - 1) value substr(line, i + length(key))
        return line
    }
    {
        line = $0
        line = replace(line, "@BIN@", ENVIRON["BIN"])
        line = replace(line, "@PORT@", ENVIRON["PORT"])
        line = replace(line, "@PASSWORD@", ENVIRON["PASSWORD"])
        print line
    }
' "$here/opencode-web.service.in" > "$unit"
chmod 600 "$unit"

# curl reads this file with -K, so the password is not put in argv.
cat > "$auth_file" <<EOF
user = "opencode:$password"
EOF
chmod 600 "$auth_file"

systemctl --user daemon-reload
systemctl --user enable opencode-web.service
systemctl --user restart opencode-web.service

echo "Installed $unit"
echo "Installed $auth_file"
echo "OpenCode listens on http://127.0.0.1:$port"
echo "Widget settings: hostname 127.0.0.1, port $port, username opencode, password blank."
