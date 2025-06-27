#!/bin/sh

# Mailpit Auto-Installer Script with systemd service

# Default Configurable Ports (can be overridden via env or CLI)
MAILPIT_UI_PORT="${MAILPIT_UI_PORT:-8025}"
MAILPIT_SMTP_PORT="${MAILPIT_SMTP_PORT:-1025}"

# Handle uninstall
if [ "$1" = "--uninstall" ]; then
    echo "🔧 Uninstalling Mailpit..."
    systemctl stop mailpit 2>/dev/null
    systemctl disable mailpit 2>/dev/null
    rm -f /etc/systemd/system/mailpit.service
    userdel mailpit 2>/dev/null
    rm -f /usr/local/bin/mailpit
    systemctl daemon-reload
    echo "✅ Mailpit uninstalled."
    exit 0
fi

# Check dependencies
for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ $cmd is required but not installed."
        exit 1
    fi
done

# Detect OS and architecture
case "$(uname -s)" in
Linux) OS="linux" ;;
Darwin) OS="Darwin" ;;
*) echo "❌ OS not supported."; exit 2 ;;
esac

case "$(uname -m)" in
x86_64 | amd64) OS_ARCH="amd64" ;;
i?86 | x86) OS_ARCH="386" ;;
aarch64 | arm64) OS_ARCH="arm64" ;;
*) echo "❌ OS architecture not supported."; exit 2 ;;
esac

GH_REPO="axllent/mailpit"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin}"
GITHUB_API_TOKEN="${GITHUB_TOKEN:-}"
TIMEOUT=90

# Allow install path override via CLI
while [ $# -gt 0 ]; do
    case $1 in
        --install-path) shift; INSTALL_PATH="$1" ;;
        --token|--auth|--github-token) shift; GITHUB_API_TOKEN="$1" ;;
    esac
    shift
done

# Fetch latest release version
if [ -n "$GITHUB_API_TOKEN" ] && [ "${#GITHUB_API_TOKEN}" -gt 36 ]; then
    CURL_OUTPUT="$(curl -sfL -m $TIMEOUT -H "Authorization: Bearer $GITHUB_API_TOKEN" https://api.github.com/repos/${GH_REPO}/releases/latest)"
else
    CURL_OUTPUT="$(curl -sfL -m $TIMEOUT https://api.github.com/repos/${GH_REPO}/releases/latest)"
fi

if command -v jq >/dev/null 2>&1; then
    VERSION=$(echo "$CURL_OUTPUT" | jq -r '.tag_name')
elif command -v awk >/dev/null 2>&1; then
    VERSION=$(echo "$CURL_OUTPUT" | awk -F: '$1 ~ /tag_name/ {gsub(/[^v0-9\.]+/, "", $2) ;print $2; exit}')
elif command -v sed >/dev/null 2>&1; then
    VERSION=$(echo "$CURL_OUTPUT" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
else
    echo "❌ Unable to extract version. Install jq/awk/sed."
    exit 3
fi

case "$VERSION" in
v[0-9][0-9\.]*) ;;
*) echo "❌ Failed to detect Mailpit version."; exit 4 ;;
esac

TEMP_DIR="$(mktemp -qd)"
[ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ] && echo "❌ Temp dir creation failed." && exit 5

cd "$TEMP_DIR" || exit 6

ARCHIVE="mailpit-${OS}-${OS_ARCH}.tar.gz"
curl -sfL -m $TIMEOUT -o "$ARCHIVE" "https://github.com/${GH_REPO}/releases/download/${VERSION}/${ARCHIVE}"
[ ! -f "$ARCHIVE" ] && echo "❌ Download failed." && exit 7

tar zxf "$ARCHIVE" || { echo "❌ Extraction failed."; exit 8; }

[ ! -d "$INSTALL_PATH" ] && mkdir -p "$INSTALL_PATH"

INSTALL_BIN_PATH="${INSTALL_PATH%/}/mailpit"
cp mailpit "$INSTALL_BIN_PATH" || { echo "❌ Copy failed."; exit 9; }
chmod 755 "$INSTALL_BIN_PATH"

# Set ownership
if [ "$(id -u)" -eq 0 ]; then
    OWNER="root"; GROUP="root"
    [ "$OS" = "Darwin" ] && GROUP="wheel"
    chown "${OWNER}:${GROUP}" "$INSTALL_BIN_PATH"
fi

rm -rf "$TEMP_DIR"
echo "✅ Mailpit installed at: $INSTALL_BIN_PATH"

# --- Setup systemd service ---
if [ "$(id -u)" -ne 0 ]; then
    echo "⚠️  Run as root to install systemd service."
    exit 0
fi

SERVICE_FILE="/etc/systemd/system/mailpit.service"

# Create user if not exists
if ! id -u mailpit >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin mailpit
    echo "✅ Created user: mailpit"
fi

chown mailpit:mailpit "$INSTALL_BIN_PATH"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mailpit SMTP and Web UI
After=network.target

[Service]
ExecStart=${INSTALL_BIN_PATH}
User=mailpit
Group=mailpit
Restart=always
Environment=MAILPIT_UI_PORT=${MAILPIT_UI_PORT}
Environment=MAILPIT_SMTP_PORT=${MAILPIT_SMTP_PORT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable mailpit
systemctl start mailpit

if systemctl is-active --quiet mailpit; then
    echo "✅ Mailpit service is running."
    echo "🌐 Web UI: http://localhost:${MAILPIT_UI_PORT}"
    echo "📬 SMTP: localhost:${MAILPIT_SMTP_PORT}"
else
    echo "❌ Mailpit service failed to start."
    echo "🔍 Check logs with: journalctl -u mailpit"
    exit 10
fi

exit 0
