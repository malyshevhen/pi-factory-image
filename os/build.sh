#!/usr/bin/env bash
# Build the factory image: base Pi OS + packages + system config + preloaded app.
#
#   sudo APP_IMAGE=ghcr.io/org/repo/app:stable os/build.sh BASE.img.xz OUT_DIR VERSION
#
# Optional env: DEVICE_SSH_AUTHORIZED_KEYS (newline-separated public keys),
# BUILD_COMMIT. Needs an arm64 Linux host: the chroot runs arm64 binaries natively.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$HERE/config.env"

BASE=$1 OUT=$2 VERSION=$3
: "${APP_IMAGE:?set APP_IMAGE to a fully-qualified image reference}"
DEVICE_SSH_AUTHORIZED_KEYS=${DEVICE_SSH_AUTHORIZED_KEYS:-}
BUILD_COMMIT=${BUILD_COMMIT:-$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)}

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "must run on an arm64 host" >&2; exit 1; }

NAME=pi-factory-$VERSION
IMG=$OUT/$NAME.img
ROOT=$(mktemp -d)
LOOP=

cleanup() {
  set +e
  umount -R "$ROOT" 2>/dev/null
  [ -n "$LOOP" ] && losetup -d "$LOOP"
  rmdir "$ROOT"
}
trap cleanup EXIT

step() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$OUT"

step "Unpacking $(basename "$BASE") and growing rootfs by $IMAGE_GROW"
xz -dc "$BASE" > "$IMG"
truncate -s "+$IMAGE_GROW" "$IMG"
echo ", +" | sfdisk --quiet --no-reread -N 2 "$IMG"
LOOP=$(losetup --find --show --partscan "$IMG")
# Exit code 1 means "errors fixed", which is fine.
e2fsck -fp "${LOOP}p2" || [ $? -le 1 ]
resize2fs "${LOOP}p2"

step "Mounting image"
mount "${LOOP}p2" "$ROOT"
mount "${LOOP}p1" "$ROOT/boot/firmware"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t tmpfs tmpfs "$ROOT/run"
mount -t tmpfs tmpfs "$ROOT/tmp"

# Borrow the host's DNS and stop package scripts from starting services.
mv "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.build-bak"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod +x "$ROOT/usr/sbin/policy-rc.d"

step "Copying overlay files"
cp -r --preserve=mode "$HERE/overlay/." "$ROOT/"
(cd "$HERE/overlay" && find . -type f) | while read -r f; do
  sed -i -e "s|@APP_IMAGE@|$APP_IMAGE|g" -e "s|@DEVICE_USER@|$DEVICE_USER|g" "$ROOT/$f"
done

step "Writing cloud-init user-data"
{
  cat "$HERE/boot/user-data"
  if [ -n "$DEVICE_SSH_AUTHORIZED_KEYS" ]; then
    echo "ssh_authorized_keys:"
    printf '%s\n' "$DEVICE_SSH_AUTHORIZED_KEYS" | sed '/^\s*$/d; s/.*/  - "&"/'
  else
    echo "WARNING: DEVICE_SSH_AUTHORIZED_KEYS is empty; devices will have no ssh access" >&2
    echo "ssh_authorized_keys: []"
  fi
} > "$ROOT/boot/firmware/user-data"

step "Customizing inside chroot"
mkdir -p "$ROOT/tmp/build"
cp "$HERE/customize.sh" "$HERE/packages.txt" "$ROOT/tmp/build/"
chroot "$ROOT" /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
  APP_IMAGE="$APP_IMAGE" DEVICE_USER="$DEVICE_USER" \
  DEVICE_HOSTNAME="$DEVICE_HOSTNAME" DEVICE_TIMEZONE="$DEVICE_TIMEZONE" \
  IMAGE_VERSION="$VERSION" BUILD_COMMIT="$BUILD_COMMIT" BASE_URL="$BASE_URL" \
  /bin/bash /tmp/build/customize.sh

rm -f "$ROOT/usr/sbin/policy-rc.d"
mv -f "$ROOT/etc/resolv.conf.build-bak" "$ROOT/etc/resolv.conf"

step "Verifying first-boot state"
# "uninitialized" makes systemd treat the next boot as first boot: that's what
# grows the rootfs and gives each device its own machine-id.
[ "$(cat "$ROOT/etc/machine-id")" = uninitialized ] || fail "/etc/machine-id was initialized"
[ ! -e "$ROOT/var/lib/dbus/machine-id" ] || fail "/var/lib/dbus/machine-id exists"
! compgen -G "$ROOT/etc/ssh/ssh_host_*" >/dev/null || fail "ssh host keys baked into image"
[ ! -e "$ROOT/var/lib/cloud/instance" ] || fail "cloud-init already ran in the image"
[ -f "$ROOT/etc/containers/systemd/myapp.container" ] || fail "quadlet unit missing"

step "Writing manifest"
{
  cat "$ROOT/etc/pi-factory-release"
  echo "BASE_SHA256=$BASE_SHA256"
  echo
  echo "# Installed packages"
  chroot "$ROOT" dpkg-query -W -f '${Package} ${Version}\n'
} > "$OUT/$NAME.manifest.txt"
cat "$ROOT/etc/pi-factory-release"

# Discard free blocks so they become holes in the image file: smaller bmap,
# faster flashing.
fstrim "$ROOT/boot/firmware" || true
fstrim "$ROOT" || true

step "Unmounting"
umount -R "$ROOT"
e2fsck -fp "${LOOP}p2" || [ $? -le 1 ]
losetup -d "$LOOP"
LOOP=

step "Packaging"
bmaptool create -o "$OUT/$NAME.img.bmap" "$IMG"
xz -T0 -6 -f "$IMG"
(cd "$OUT" && sha256sum "$NAME.img.xz" "$NAME.img.bmap" > "$NAME.sha256" && cat "$NAME.sha256")
ls -lh "$OUT"
