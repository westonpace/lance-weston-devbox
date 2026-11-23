#!/usr/bin/env bash
# EC2 user data for the devbox HOST. Paste into a Launch Template's user data
# (Ubuntu 24.04 AMI). The host stays deliberately dumb: Docker, a big data
# volume, a registry login. Everything that defines the dev environment lives
# in the image, so tweaking the environment never means a new AMI.
#
# Instance role needs: ssm:GetParameter on GHCR_TOKEN_PARAM and kms:Decrypt
# for the key that parameter uses.
set -euxo pipefail

# ---- settings --------------------------------------------------------------
IMAGE="${IMAGE:-ghcr.io/westonpace/lance-weston-devbox:latest}"
GHCR_USER="${GHCR_USER:-westonpace}"
GHCR_TOKEN_PARAM="${GHCR_TOKEN_PARAM:-/devbox/ghcr-token}"
DATA_DEVICE="${DATA_DEVICE:-/dev/nvme1n1}"
DATA_MOUNT="${DATA_MOUNT:-/data}"
# Minutes of idleness before the instance stops itself. Empty disables it.
IDLE_SHUTDOWN_MINUTES="${IDLE_SHUTDOWN_MINUTES:-}"

# ---- docker engine ---------------------------------------------------------
apt-get update
apt-get install -y ca-certificates curl unzip awscli
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu

# ---- data volume -----------------------------------------------------------
# Images, named caches and three separate target/ trees are what actually fill
# a disk here, so put Docker's data-root on the big EBS volume rather than
# oversizing the root volume.
if [ -b "$DATA_DEVICE" ]; then
  blkid "$DATA_DEVICE" >/dev/null 2>&1 || mkfs.ext4 -m 0 "$DATA_DEVICE"
  mkdir -p "$DATA_MOUNT"
  uuid="$(blkid -s UUID -o value "$DATA_DEVICE")"
  grep -q "$uuid" /etc/fstab || \
    echo "UUID=$uuid $DATA_MOUNT ext4 defaults,nofail,discard 0 2" >> /etc/fstab
  mount -a

  systemctl stop docker docker.socket || true
  mkdir -p "$DATA_MOUNT/docker"
  mkdir -p /etc/docker
  printf '{\n  "data-root": "%s/docker"\n}\n' "$DATA_MOUNT" > /etc/docker/daemon.json
  systemctl start docker

  install -d -o ubuntu -g ubuntu "$DATA_MOUNT/workspace"
fi

# ---- registry login --------------------------------------------------------
# The token is read from SSM Parameter Store rather than embedded here: user
# data is readable by anything that can reach IMDS from the instance.
if token="$(aws ssm get-parameter --name "$GHCR_TOKEN_PARAM" --with-decryption \
            --query Parameter.Value --output text 2>/dev/null)"; then
  install -d -o ubuntu -g ubuntu /home/ubuntu/.docker
  echo "$token" | sudo -u ubuntu docker login ghcr.io -u "$GHCR_USER" --password-stdin
  sudo -u ubuntu docker pull "$IMAGE" || true
fi

# ---- idle auto-stop --------------------------------------------------------
# Guards on BOTH no interactive sessions and low load, so a long unattended
# `cargo build` or test run does not get the instance stopped out from under
# it.
if [ -n "$IDLE_SHUTDOWN_MINUTES" ]; then
  cat > /usr/local/bin/devbox-idle-stop <<'IDLE'
#!/usr/bin/env bash
set -euo pipefail
THRESHOLD_MINUTES="${1:-60}"
STATE=/var/lib/devbox-idle

sessions="$(who | wc -l)"
execs="$(docker ps -q 2>/dev/null | xargs -r -I{} docker top {} -o pid 2>/dev/null | grep -c . || true)"
load="$(awk '{print int($1 * 100)}' /proc/loadavg)"

# Busy if someone is logged in, or the machine is doing real work.
if [ "$sessions" -gt 0 ] || [ "$load" -gt 50 ]; then
  rm -f "$STATE"
  exit 0
fi

now="$(date +%s)"
[ -f "$STATE" ] || echo "$now" > "$STATE"
since="$(cat "$STATE")"
if [ $(( (now - since) / 60 )) -ge "$THRESHOLD_MINUTES" ]; then
  logger -t devbox-idle "idle for ${THRESHOLD_MINUTES}m, stopping instance"
  shutdown -h now
fi
IDLE
  chmod +x /usr/local/bin/devbox-idle-stop

  cat > /etc/systemd/system/devbox-idle.service <<SERVICE
[Unit]
Description=Stop the devbox host when idle

[Service]
Type=oneshot
ExecStart=/usr/local/bin/devbox-idle-stop ${IDLE_SHUTDOWN_MINUTES}
SERVICE

  cat > /etc/systemd/system/devbox-idle.timer <<'TIMER'
[Unit]
Description=Periodic idle check for the devbox host

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now devbox-idle.timer
fi

# Requires the instance's "Shutdown behavior" to be `stop`, not `terminate`,
# or the EBS caches are destroyed along with the instance.
