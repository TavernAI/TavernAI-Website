#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${TAVERNAI_INSTALL_DIR:-$HOME/TavernAI}"
GITHUB_REPO="${TAVERNAI_GITHUB_REPO:-TavernAI/TavernAI}"
RELEASE_API_URL="${TAVERNAI_RELEASE_API_URL:-https://api.github.com/repos/$GITHUB_REPO/releases/latest}"
INSTALL_SCRIPT_URL="${TAVERNAI_INSTALL_SCRIPT_URL:-https://tavernai.net/install.sh}"
SKIP_SERVICE_PROMPT="${TAVERNAI_SKIP_SERVICE_PROMPT:-0}"
CLEAN_INSTALL_DIR="${TAVERNAI_CLEAN_INSTALL_DIR:-0}"
ALLOW_LIVE_UPDATE="${TAVERNAI_ALLOW_LIVE_UPDATE:-0}"
RELEASE_EDITION="${TAVERNAI_RELEASE_EDITION:-auto}"

resolve_download_url() {
  release_json="$1"
  edition_preference=$(printf '%s' "$RELEASE_EDITION" | tr '[:upper:]' '[:lower:]')

  case "$edition_preference" in
    ""|auto)
      edition_preference="standard pro generic"
      ;;
    standard|pro|generic)
      ;;
    *)
      echo "Unsupported TAVERNAI_RELEASE_EDITION: $RELEASE_EDITION" >&2
      echo "Use auto, standard, pro, or generic." >&2
      return 2
      ;;
  esac

  urls=$(printf '%s' "$release_json" \
    | grep '"browser_download_url"' \
    | cut -d '"' -f 4 || true)

  for edition in $edition_preference; do
    selected_url=$(printf '%s\n' "$urls" | awk -v platform="$PLATFORM" -v edition="$edition" '
      {
        url = $0
        name = url
        sub(/^.*\//, "", name)
        lname = tolower(name)
        lurl = tolower(url)

        if (lurl !~ platform) next
        if (lname !~ /\.tar\.gz$/) next
        if (lname !~ /tavernai/) next
        if (lname ~ /map/) next
        if (lname ~ /unprotected/) next

        has_standard = lname ~ /(^|[-_.])standard([-_.]|$)/
        has_pro = lname ~ /(^|[-_.])pro([-_.]|$)/

        if (edition == "standard" && has_standard) { print url; exit }
        if (edition == "pro" && has_pro) { print url; exit }
        if (edition == "generic" && !has_standard && !has_pro) { print url; exit }
      }
    ')

    if [ -n "$selected_url" ]; then
      printf '%s\n' "$selected_url"
      return 0
    fi
  done

  return 1
}

fail_if_tavernai_is_running() {
  if [ "$CLEAN_INSTALL_DIR" != "1" ] || [ "$ALLOW_LIVE_UPDATE" = "1" ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tavernai 2>/dev/null; then
    echo "TavernAI systemd service is running."
    echo "Stop it before updating:"
    echo "  sudo systemctl stop tavernai"
    echo "  cd $INSTALL_DIR && ./updater/update.sh"
    echo "  sudo systemctl start tavernai"
    exit 1
  fi

  if [ ! -d "$INSTALL_DIR" ] || [ ! -d /proc ]; then
    return 0
  fi

  INSTALL_DIR_REAL=$(cd "$INSTALL_DIR" && pwd -P)
  RUNNING_PID=""
  RUNNING_EXE=""

  for proc_exe in /proc/[0-9]*/exe; do
    [ -e "$proc_exe" ] || continue

    proc_pid="${proc_exe#/proc/}"
    proc_pid="${proc_pid%/exe}"
    if [ "$proc_pid" = "$$" ]; then
      continue
    fi

    exe_path=$(readlink "$proc_exe" 2>/dev/null || true)
    exe_path="${exe_path% (deleted)}"
    case "$exe_path" in
      "$INSTALL_DIR_REAL"/*)
        RUNNING_PID="$proc_pid"
        RUNNING_EXE="$exe_path"
        break
        ;;
    esac
  done

  if [ -n "$RUNNING_PID" ]; then
    echo "TavernAI appears to be running from this installation."
    echo "Process: $RUNNING_PID"
    echo "Executable: $RUNNING_EXE"
    echo "Close TavernAI before updating, then run ./updater/update.sh again."
    exit 1
  fi
}

case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  linux*)
    PLATFORM="linux-x64"
    ARCHIVE_NAME="tavernai.tar.gz"
    ;;
  darwin*)
    echo "macOS command-line install is not available yet."
    echo "Download manually: https://github.com/$GITHUB_REPO/releases/latest"
    exit 1
    ;;
  *)
    echo "Unsupported OS: $(uname -s)"
    echo "Download manually: https://github.com/$GITHUB_REPO/releases/latest"
    exit 1
    ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required."; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required."; exit 1; }

echo "Installing TavernAI 2 for $PLATFORM"
echo "Directory: $INSTALL_DIR"

DOWNLOAD_URL="${TAVERNAI_DOWNLOAD_URL:-}"
if [ -z "$DOWNLOAD_URL" ]; then
  RELEASE_JSON=$(curl -fsSL "$RELEASE_API_URL")
  DOWNLOAD_URL=$(resolve_download_url "$RELEASE_JSON" || true)
fi

if [ -z "$DOWNLOAD_URL" ]; then
  echo "Release archive not found for $PLATFORM."
  echo "Edition preference: $RELEASE_EDITION"
  echo "Checked: $RELEASE_API_URL"
  exit 1
fi

TEMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Downloading TavernAI archive..."
curl -fL --progress-bar "$DOWNLOAD_URL" -o "$TEMP_DIR/$ARCHIVE_NAME"

EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
echo "Preparing archive..."
tar -xzf "$TEMP_DIR/$ARCHIVE_NAME" -C "$EXTRACT_DIR"

SOURCE_DIR="$EXTRACT_DIR/TavernAI"
if [ ! -d "$SOURCE_DIR" ]; then
  SOURCE_DIR="$EXTRACT_DIR"
fi

if [ ! -f "$SOURCE_DIR/TavernAI" ] && [ ! -f "$SOURCE_DIR/core/TavernAI.Backend" ]; then
  echo "Downloaded archive does not look like a TavernAI Linux build."
  exit 1
fi

fail_if_tavernai_is_running

mkdir -p "$INSTALL_DIR"
if [ "$CLEAN_INSTALL_DIR" = "1" ]; then
  echo "Cleaning old application files..."
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 \
    ! -name 'user_data' \
    ! -name 'logs' \
    ! -name 'config.yaml' \
    ! -name 'models' \
    -exec rm -rf {} +
fi

echo "Installing files..."
if [ "$CLEAN_INSTALL_DIR" = "1" ]; then
  find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name 'user_data' \
    ! -name 'logs' \
    ! -name 'config.yaml' \
    ! -name 'models' \
    -exec cp -a {} "$INSTALL_DIR/" \;
else
  cp -a "$SOURCE_DIR/." "$INSTALL_DIR/"
fi

UPDATER_DIR="$INSTALL_DIR/updater"
UPDATER_SCRIPT="$UPDATER_DIR/update.sh"
if [ -f "$UPDATER_SCRIPT" ]; then
  chmod +x "$UPDATER_SCRIPT" || true
else
  mkdir -p "$UPDATER_DIR"
  cat > "$UPDATER_SCRIPT" << EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="\$(cd "\$SCRIPT_DIR/.." && pwd)"
INSTALL_SCRIPT_URL="\${TAVERNAI_INSTALL_SCRIPT_URL:-$INSTALL_SCRIPT_URL}"
RELEASE_EDITION="\${TAVERNAI_RELEASE_EDITION:-$RELEASE_EDITION}"

echo "Updating TavernAI with legacy installer wrapper..."
if ! curl -fsSL "\$INSTALL_SCRIPT_URL" | TAVERNAI_INSTALL_DIR="\$APP_DIR" TAVERNAI_RELEASE_EDITION="\$RELEASE_EDITION" TAVERNAI_SKIP_SERVICE_PROMPT=1 TAVERNAI_CLEAN_INSTALL_DIR=1 bash; then
  echo "Update failed. Preserved local folders were not removed: user_data, logs, models, config.yaml."
  exit 1
fi

echo "Updated."
echo "Desktop start: cd \$APP_DIR && ./TavernAI"
echo "VPS start:     cd \$APP_DIR && ./core/TavernAI.Backend"
EOF
  chmod +x "$UPDATER_SCRIPT"
fi

if [ -f "$INSTALL_DIR/TavernAI" ]; then
  chmod +x "$INSTALL_DIR/TavernAI" || true
fi
if [ -f "$INSTALL_DIR/core/TavernAI.Backend" ]; then
  chmod +x "$INSTALL_DIR/core/TavernAI.Backend" || true
fi
if [ -f "$INSTALL_DIR/install-desktop-entry.sh" ]; then
  chmod +x "$INSTALL_DIR/install-desktop-entry.sh" || true
fi

if command -v systemctl >/dev/null 2>&1 && [ "$SKIP_SERVICE_PROMPT" != "1" ]; then
  answer=""
  if [ -r /dev/tty ]; then
    printf "Install systemd service for auto-start? [y/N] " > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    echo "Skipping systemd service prompt because no interactive terminal is attached."
  fi

  if [[ "${answer,,}" == "y" ]]; then
    SERVICE_COMMAND="$INSTALL_DIR/core/TavernAI.Backend"
    if [ ! -x "$SERVICE_COMMAND" ]; then
      SERVICE_COMMAND="$INSTALL_DIR/TavernAI"
    fi

    sudo tee /etc/systemd/system/tavernai.service >/dev/null << SVCEOF
[Unit]
Description=TavernAI 2
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$SERVICE_COMMAND
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    sudo systemctl daemon-reload
    sudo systemctl enable tavernai
    sudo systemctl start tavernai
    echo "Service started. Check it with: sudo systemctl status tavernai"
  fi
fi

echo ""
echo "TavernAI 2 installed at $INSTALL_DIR"
echo "Desktop start: cd $INSTALL_DIR && ./TavernAI"
echo "VPS start:     cd $INSTALL_DIR && ./core/TavernAI.Backend"
echo "Update:        cd $INSTALL_DIR && ./updater/update.sh"