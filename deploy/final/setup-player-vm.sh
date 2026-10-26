#!/usr/bin/env bash
# Sets up a player VM the way deploy/vm/Dockerfile sets up the simulated
# ones: an unprivileged `deploy` user that the platform logs in to with its
# key, and /home/deploy/releases, where the release is unpacked and run. A
# release ships its own Erlang runtime, so nothing else is installed.
#
#   sudo deploy/final/setup-player-vm.sh "ssh-ed25519 AAAA... wikirace-deploy-dev"
#   sudo deploy/final/setup-player-vm.sh --lockdown
#   sudo deploy/final/setup-player-vm.sh --unlock
#
# The key is the one setup-platform-vm.sh prints.
#
# --lockdown applies the rules that docker-compose.yml gives the simulated
# player VMs: no internet, and no access to the other player VM. Outgoing
# traffic may only go to Kiwix (port 8080 on the Wikipedia VM) and to the
# platform. Incoming traffic is SSH, plus epmd and the distribution ports
# from the platform. Run it after the setup. --unlock removes the rules.

set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_root
load_env WIKI_IP PLATFORM_IP PLAYER1_IP PLAYER2_IP

lockdown() {
  apt-get install -y ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  # reject, not deny, so a blocked request fails at once instead of hanging.
  ufw default reject outgoing
  ufw allow in 22/tcp
  ufw allow in from "$PLATFORM_IP" to any port 4369 proto tcp
  ufw allow in from "$PLATFORM_IP" to any port 9100:9109 proto tcp
  ufw allow out to "$WIKI_IP" port 8080 proto tcp
  ufw allow out to "$PLATFORM_IP"
  ufw --force enable
  ufw status verbose
}

case "${1:-}" in
  --lockdown) lockdown; exit 0 ;;
  --unlock) ufw --force reset; ufw --force disable; exit 0 ;;
  ssh-*) pubkey="$1" ;;
  *) die "usage: $0 \"<public key printed by setup-platform-vm.sh>\" | --lockdown | --unlock" ;;
esac

step "Packages"
apt-get update -q
apt-get install -y curl ca-certificates
set_kiwix_host

step "deploy user"
if ! id deploy >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash deploy
fi
# `*`, not the locked `!`. OpenSSH can refuse even key logins for a
# locked account. This user never logs in with a password.
usermod -p '*' deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo "$pubkey" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
install -d -o deploy -g deploy /home/deploy/releases
# The release runs as a daemon started from an SSH session. Lingering keeps
# it alive after the session closes.
loginctl enable-linger deploy

step "Kiwix from this VM"
code=$(curl -s -o /dev/null -w '%{http_code}' -L "http://kiwix1:8080/" || true)
[ "$code" = 200 ] && echo "ok" || echo "warning: http://kiwix1:8080 answered HTTP $code. Is the Wikipedia VM set up?"

echo
echo "Done. Check from the platform VM with: deploy/final/wikirace check"
