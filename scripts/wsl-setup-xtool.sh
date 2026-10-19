#!/usr/bin/env bash
# Idempotent setup script for xtool and iOS USB tools inside WSL2 Ubuntu (24.04 LTS)
# Usage:
#   bash .agents/skills/xtool-ios/scripts/wsl-setup-xtool.sh [--with-swift]

set -euo pipefail

WITH_SWIFT=false
for arg in "$@"; do
  case "$arg" in
    --with-swift)
      WITH_SWIFT=true
      ;;
  esac
done

echo "=== [1/4] Checking WSL2 Ubuntu Environment ==="
uname -a
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "Distribution: ${PRETTY_NAME:-Ubuntu}"
fi

echo "=== [2/4] Checking System Prerequisites (usbmuxd, libimobiledevice-utils, socat, zip, libfuse2) ==="
MISSING_PKGS=()
for cmd_pkg in "usbmuxd:usbmuxd" "ideviceinfo:libimobiledevice-utils" "socat:socat" "curl:curl" "unzip:unzip" "zip:zip"; do
  cmd="${cmd_pkg%%:*}"
  pkg="${cmd_pkg##*:}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if ! dpkg -s libfuse2t64 >/dev/null 2>&1 && ! dpkg -s libfuse2 >/dev/null 2>&1; then
  MISSING_PKGS+=("libfuse2t64")
fi

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing missing packages: ${MISSING_PKGS[*]}"
  if [ "$(id -u)" -eq 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${MISSING_PKGS[@]}"
  elif sudo -n true 2>/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PKGS[@]}"
  else
    echo "NOTE: sudo requires a password. Run from Windows PowerShell as root if needed:"
    echo "  wsl -d Ubuntu -u root -- apt-get update && wsl -d Ubuntu -u root -- apt-get install -y ${MISSING_PKGS[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PKGS[@]}"
  fi
else
  echo "All apt packages already installed:"
  echo "  - usbmuxd:     $(command -v usbmuxd)"
  echo "  - ideviceinfo: $(command -v ideviceinfo)"
  echo "  - socat:       $(command -v socat)"
  echo "  - zip/unzip:   $(command -v zip), $(command -v unzip)"
fi

echo "=== [2b/4] Ensuring Apple Root CA is Trusted in WSL2 ==="
if [ ! -f /usr/local/share/ca-certificates/Apple_Root_CA.crt ]; then
  echo "Installing Apple Root CA for Apple GrandSlam/Developer TLS verification..."
  if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    SUDO_PREFIX=""
    [ "$(id -u)" -ne 0 ] && SUDO_PREFIX="sudo"
    $SUDO_PREFIX bash -c "cat << 'EOF' > /usr/local/share/ca-certificates/Apple_Root_CA.crt
-----BEGIN CERTIFICATE-----
MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET
MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv
biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0
MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+
+FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1
XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w
tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW
q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM
aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E
BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3
R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE
ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93
d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl
IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0
YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj
b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp
Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc
NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP
y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7
R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg
xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP
IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX
UKqK1drk/NAJBzewdXUh
-----END CERTIFICATE-----
EOF
update-ca-certificates"
  fi
fi

echo "=== [3/4] Installing xtool Prebuilt AppImage in User Space (~/.local/bin/xtool) ==="
ARCH="$(uname -m)"
if [ "$ARCH" = "x86_64" ]; then
  XTOOL_ASSET="xtool-x86_64.AppImage"
elif [ "$ARCH" = "aarch64" ]; then
  XTOOL_ASSET="xtool-aarch64.AppImage"
else
  echo "Unsupported architecture: $ARCH" >&2
  exit 1
fi

XTOOL_VERSION="${XTOOL_VERSION:-1.22.0}"
XTOOL_URL="https://github.com/xtool-org/xtool/releases/download/${XTOOL_VERSION}/${XTOOL_ASSET}"
XTOOL_DIR="${HOME}/.local/share/xtool"
BIN_DIR="${HOME}/.local/bin"

mkdir -p "$XTOOL_DIR" "$BIN_DIR"

if [ -x "${BIN_DIR}/xtool" ] && "${BIN_DIR}/xtool" --version 2>/dev/null | grep -q "${XTOOL_VERSION}"; then
  echo "xtool ${XTOOL_VERSION} is already installed at ${BIN_DIR}/xtool"
else
  echo "Downloading ${XTOOL_URL} ..."
  curl -fL --retry 3 -o "${XTOOL_DIR}/${XTOOL_ASSET}" "$XTOOL_URL"
  chmod +x "${XTOOL_DIR}/${XTOOL_ASSET}"

  echo "Extracting AppImage (--appimage-extract) so FUSE is not required at runtime..."
  (
    cd "$XTOOL_DIR"
    rm -rf squashfs-root
    "./${XTOOL_ASSET}" --appimage-extract >/dev/null
  )
  ln -sf "${XTOOL_DIR}/squashfs-root/AppRun" "${BIN_DIR}/xtool"
fi

if ! grep -q '.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
fi
export PATH="${BIN_DIR}:${PATH}"

echo "Verified xtool binary: $(command -v xtool)"
echo "Verified xtool version: $(xtool --version)"

if [ "$WITH_SWIFT" = true ]; then
  echo "=== [4/4] Installing Swift Toolchain via swiftly (--with-swift) ==="
  if command -v swift >/dev/null 2>&1; then
    echo "Swift already installed: $(swift --version | head -n 1)"
  else
    TMP_SWIFTLY="$(mktemp -d)"
    (
      cd "$TMP_SWIFTLY"
      curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-${ARCH}.tar.gz"
      tar zxf "swiftly-${ARCH}.tar.gz"
      ./swiftly init --quiet-shell-followup -y
    )
    rm -rf "$TMP_SWIFTLY"
    # shellcheck disable=SC1090
    [ -f "${HOME}/.local/share/swiftly/env.sh" ] && . "${HOME}/.local/share/swiftly/env.sh"
    swiftly install 6.4-snapshot || swiftly install latest
    swift --version
  fi
else
  echo "=== [4/4] Skipping Swift compiler install (not required for xtool auth/devices/install; pass --with-swift to install) ==="
fi

echo "=== WSL2 xtool Setup Complete! ==="
