#!/bin/bash
# Runs inside the image chroot (arm64), called by build.sh. Inputs come from env.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { echo "==> $*"; }

step "Installing packages"
apt-get update
grep -vE '^\s*(#|$)' /tmp/build/packages.txt | xargs apt-get install -y
apt-get clean
rm -rf /var/lib/apt/lists/*

step "Setting up user $DEVICE_USER"
# Rename the stock "pi" user, then do what userconf-pi's cancel-rename does,
# minus the interactive parts: no first-boot wizard, no rename-time ssh login.
if [ "$DEVICE_USER" != pi ] && id pi >/dev/null 2>&1; then
  usermod -l "$DEVICE_USER" -d "/home/$DEVICE_USER" -m pi
  groupmod -n "$DEVICE_USER" pi
  sed -i "s/^pi:/$DEVICE_USER:/" /etc/subuid /etc/subgid
fi
usermod -s /bin/bash "$DEVICE_USER"
passwd -l "$DEVICE_USER"
rm -f /etc/ssh/sshd_config.d/rename_user.conf
systemctl disable userconfig.service
systemctl enable getty@tty1.service ssh.service podman-auto-update.timer

step "System settings"
echo "$DEVICE_HOSTNAME" > /etc/hostname
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$DEVICE_HOSTNAME/" /etc/hosts
ln -sf "/usr/share/zoneinfo/$DEVICE_TIMEZONE" /etc/localtime
echo "$DEVICE_TIMEZONE" > /etc/timezone

step "Preloading $APP_IMAGE"
# Pull from the registry (not podman load) so the stored digest matches the
# registry and the first auto-update check doesn't re-download the same image.
podman --events-backend=none pull "$APP_IMAGE"
APP_DIGEST=$(podman --events-backend=none image inspect --format '{{.Digest}}' "$APP_IMAGE")
podman --events-backend=none images

step "Validating quadlet units"
/usr/lib/systemd/system-generators/podman-system-generator --dryrun

cat > /etc/pi-factory-release <<EOF
IMAGE_VERSION=$IMAGE_VERSION
BUILD_COMMIT=$BUILD_COMMIT
BASE_IMAGE=$BASE_URL
APP_IMAGE=$APP_IMAGE
APP_DIGEST=$APP_DIGEST
PODMAN_VERSION=$(dpkg-query -W -f '${Version}' podman)
EOF
