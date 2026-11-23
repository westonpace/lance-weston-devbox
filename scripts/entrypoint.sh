#!/usr/bin/env bash
# Align the container's view of the Docker socket group with the host's, then
# drop to the unprivileged user.
#
# The host's `docker` group GID is not knowable at build time -- it differs
# between Ubuntu, Amazon Linux and a laptop -- so it has to be reconciled at
# start, or `docker` and `make integtest` fail with EACCES on the socket.
set -euo pipefail

USERNAME="${DEVBOX_USER:-lance}"
SOCKET=/var/run/docker.sock

if [ "$(id -u)" -eq 0 ]; then
  if [ -S "$SOCKET" ]; then
    sock_gid="$(stat -c '%g' "$SOCKET")"
    if ! getent group "$sock_gid" >/dev/null; then
      groupadd -g "$sock_gid" docker-host
    fi
    usermod -aG "$(getent group "$sock_gid" | cut -d: -f1)" "$USERNAME"
  fi
  exec setpriv --reuid="$USERNAME" --regid="$USERNAME" --init-groups -- "$@"
fi

# Already unprivileged (e.g. `docker run --user`); nothing to reconcile.
exec "$@"
