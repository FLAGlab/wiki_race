#!/usr/bin/env bash
# Sets up the platform VM: Erlang and Elixir in /opt/wikirace (they run the
# platform and build the releases of the groups, no Docker), the SSH key
# that logs in to the player VMs, and the platform's dependencies and assets.
#
#   sudo deploy/final/setup-platform-vm.sh
#
# At the end it prints the public key to install on both player VMs.

set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root
load_env WIKI_IP PLATFORM_IP PLAYER1_IP PLAYER2_IP KIWIX_BOOK

as_user() { sudo -u "$SUDO_USER" env PATH="$ELIXIR_DIR/bin:$OTP_DIR/bin:$PATH" "$@"; }

step "Packages"
apt-get update -q
apt-get install -y curl unzip git make ca-certificates openssh-client inotify-tools
set_kiwix_host

step "Erlang/OTP $OTP_VERSION and Elixir $ELIXIR_VERSION in $BEAM_DIR"
tmp=$(mktemp -d)
if [ ! -x "$OTP_DIR/bin/erl" ]; then
  curl -fsSL -o "$tmp/otp.tar.gz" "https://builds.hex.pm/builds/otp/ubuntu-26.04/OTP-$OTP_VERSION.tar.gz"
  echo "$OTP_SHA256  $tmp/otp.tar.gz" | sha256sum -c -
  mkdir -p "$OTP_DIR"
  tar -xzf "$tmp/otp.tar.gz" -C "$OTP_DIR" --strip-components=1
  (cd "$OTP_DIR" && ./Install -minimal "$OTP_DIR" >/dev/null)
fi
if [ ! -x "$ELIXIR_DIR/bin/elixir" ]; then
  curl -fsSL -o "$tmp/elixir.zip" "https://builds.hex.pm/builds/elixir/v$ELIXIR_VERSION-otp-28.zip"
  mkdir -p "$ELIXIR_DIR"
  unzip -q -o "$tmp/elixir.zip" -d "$ELIXIR_DIR"
fi
rm -rf "$tmp"
echo "export PATH=\"$ELIXIR_DIR/bin:$OTP_DIR/bin:\$PATH\"" > /etc/profile.d/wikirace.sh
as_user elixir -e 'IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}")'

step "Deploy key"
as_user make -C "$REPO_ROOT" deploy-keys

step "Platform dependencies and assets"
as_user bash -c "cd '$REPO_ROOT/platform' && mix local.hex --force && mix local.rebar --force && mix setup"

step "Kiwix from this VM"
code=$(curl -s -o /dev/null -w '%{http_code}' -L "http://kiwix1:8080/content/$KIWIX_BOOK/Tiger" || true)
[ "$code" = 200 ] && echo "ok" || echo "warning: http://kiwix1:8080 answered HTTP $code. Is the Wikipedia VM set up?"

echo
echo "Done. Install this public key on both player VMs (setup-player-vm.sh takes it as its argument):"
echo
cat "$REPO_ROOT/deploy/keys/id_ed25519.pub"
