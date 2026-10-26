# Shared by the scripts in deploy/final/. Sourced, never run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINAL_DIR="$REPO_ROOT/deploy/final"
ENV_FILE="$FINAL_DIR/final.env"

# Same versions as /.tool-versions and the release builder image
# (deploy/vm/Dockerfile), built by hex.pm for Ubuntu 26.04. The VMs have no
# Docker: the platform VM builds the releases with these.
OTP_VERSION=28.5.0.4
OTP_SHA256=af3a11aae340a95762df20c0132c8ad2662e3614ffe739a4f349017f17e424cd
ELIXIR_VERSION=1.20.2
BEAM_DIR=/opt/wikirace
OTP_DIR="$BEAM_DIR/otp-$OTP_VERSION"
ELIXIR_DIR="$BEAM_DIR/elixir-$ELIXIR_VERSION"

# kiwix-serve on the Wikipedia VM: the static build, the same program the
# kiwix-serve Docker image of the local setup runs.
KIWIX_TOOLS_VERSION=3.8.2
KIWIX_DIR="$BEAM_DIR/kiwix-tools-$KIWIX_TOOLS_VERSION"

# Same flags the deploy passes to every player release (see
# @player_erl_flags in platform/lib/wiki_race_platform/deploy/server.ex).
export ERL_AFLAGS="-kernel prevent_overlapping_partitions false inet_dist_listen_min 9100 inet_dist_listen_max 9109"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Loads final.env and checks that every variable named in "$@" is set.
load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Copy final.env.example to final.env and fill it in."
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  for var in "$@"; do
    [ -n "${!var:-}" ] || die "$var is empty in $ENV_FILE"
  done
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run this script with sudo"
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || die "run it with sudo from your normal user, not as root"
}

# Points the name kiwix1 at the Wikipedia VM, the same name the local
# docker-compose setup uses, so a crawler that works locally finds Kiwix here.
set_kiwix_host() {
  sed -i '/[[:space:]]kiwix1$/d' /etc/hosts
  echo "$WIKI_IP kiwix1" >> /etc/hosts
}
