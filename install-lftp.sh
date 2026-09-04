#!/usr/bin/env bash
# Builds lftp from source linked against OpenSSL. Ubuntu's stock `apt install
# lftp` links against GnuTLS, which has documented TLS session-resumption
# problems on the FTPS data channel against servers (e.g. Pure-FTPd) that
# enforce control/data session reuse — see README for the symptom pattern.

set -euo pipefail

LFTP_VERSION="4.9.2"
LFTP_URL="https://lftp.yar.ru/ftp/lftp-${LFTP_VERSION}.tar.xz"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libssl-dev libreadline-dev libncurses-dev zlib1g-dev pkg-config wget

echo "Downloading lftp $LFTP_VERSION source..."
wget -q "$LFTP_URL" -O "$BUILD_DIR/lftp.tar.xz"
tar xf "$BUILD_DIR/lftp.tar.xz" -C "$BUILD_DIR"

cd "$BUILD_DIR/lftp-${LFTP_VERSION}"
./configure --with-openssl --without-gnutls --prefix=/usr/local >/dev/null
make -j"$(nproc)" >/dev/null
sudo make install >/dev/null
cd - >/dev/null

hash -r
echo "Installed: $(lftp --version | head -1)"
