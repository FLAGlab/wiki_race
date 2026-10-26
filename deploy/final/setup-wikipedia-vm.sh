#!/usr/bin/env bash
# Sets up the Wikipedia VM: the ZIM snapshot and kiwix-serve on port 8080, as
# the systemd service wikirace-kiwix, started on boot. No Docker.
#
#   sudo deploy/final/setup-wikipedia-vm.sh
#
# The full snapshot is 52 GB. Run this inside tmux, or copy the file from a
# machine that has it to .data/zim/<KIWIX_BOOK>.zim first, and the download
# is skipped.

set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root
load_env WIKI_IP KIWIX_BOOK

step "Packages"
apt-get update -q
apt-get install -y curl make ca-certificates

step "kiwix-serve $KIWIX_TOOLS_VERSION in $KIWIX_DIR"
if [ ! -x "$KIWIX_DIR/kiwix-serve" ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/kiwix.tar.gz" \
    "https://download.kiwix.org/release/kiwix-tools/kiwix-tools_linux-x86_64-$KIWIX_TOOLS_VERSION.tar.gz"
  tar -xzf "$tmp/kiwix.tar.gz" -C "$tmp"
  bin=$(find "$tmp" -name kiwix-serve -type f | head -1)
  [ -n "$bin" ] || die "no kiwix-serve in the kiwix-tools archive"
  mkdir -p "$KIWIX_DIR"
  cp -a "$(dirname "$bin")"/. "$KIWIX_DIR"/
  rm -rf "$tmp"
fi
"$KIWIX_DIR/kiwix-serve" --version | head -1

zim="$REPO_ROOT/.data/zim/$KIWIX_BOOK.zim"
step "Snapshot $zim"
if [ ! -f "$zim" ]; then
  free_gb=$(df --output=avail -BG "$REPO_ROOT" | tail -1 | tr -dc 0-9)
  [ "$free_gb" -ge 60 ] || die "only ${free_gb} GB free in $REPO_ROOT, the full snapshot needs about 55 GB"
fi
# The Makefile pins the dated file name of each snapshot.
sudo -u "$SUDO_USER" make -C "$REPO_ROOT" fetch-zim KIWIX_BOOK="$KIWIX_BOOK"

step "Service wikirace-kiwix"
# The default is 4 threads. Two crawlers in parallel need more.
cat > /etc/systemd/system/wikirace-kiwix.service <<EOF
[Unit]
Description=WikiRace offline Wikipedia (kiwix-serve)
After=network-online.target
Wants=network-online.target

[Service]
User=$SUDO_USER
ExecStart=$KIWIX_DIR/kiwix-serve --port=8080 --threads $(nproc) $zim
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wikirace-kiwix
systemctl restart wikirace-kiwix

for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -L "http://localhost:8080/content/$KIWIX_BOOK/Tiger" || true)
  [ "$code" = 200 ] && break
  sleep 2
done
[ "$code" = 200 ] || die "Kiwix does not serve /content/$KIWIX_BOOK/Tiger (HTTP $code). See: journalctl -u wikirace-kiwix"

echo
echo "Kiwix is serving http://$WIKI_IP:8080/content/$KIWIX_BOOK/ with $(nproc) threads."
