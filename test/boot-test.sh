#!/usr/bin/env bash
# Boot a factory image in QEMU (raspi3b machine, the image's own kernel and
# device tree) and check the device comes up the way it will in the field.
#
#   test/boot-test.sh dist/pi-factory-X.img.xz
#
# The only change to the test copy is an extra ssh key appended to the
# cloud-init user-data, so first boot runs exactly as it will on a device.
# Needs: qemu-system-aarch64, qemu-img, mtools, openssh-client, curl. No root.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../os/config.env
. "$HERE/../os/config.env"

IMG_XZ=$(realpath "$1")
WORK=${WORK:-$(mktemp -d)}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1500}
SSH_PORT=2222 APP_PORT=8080
mkdir -p "$WORK" && cd "$WORK"

step() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "Preparing test copy in $WORK"
xz -dc "$IMG_XZ" > disk.img
OFF=$(( $(partx -g -o START -n 1 disk.img) * 512 ))
M=(-i "disk.img@@$OFF")
mcopy -n "${M[@]}" ::/kernel8.img ::/bcm2710-rpi-3-b.dtb ::/initramfs8 ::/cmdline.txt ::/user-data .

ssh-keygen -q -t ed25519 -N '' -C boot-test -f id_test
sed -i 's/^ssh_authorized_keys: \[\]$/ssh_authorized_keys:/' user-data
echo "  - \"$(cat id_test.pub)\"" >> user-data
mcopy -o "${M[@]}" user-data ::/user-data

# QEMU's raspi3b exposes the PL011 UART as the console.
sed -i 's/console=serial0,[0-9]*/console=ttyAMA0,115200/' cmdline.txt
# SD card size must be a power of two; this also exercises first-boot resize.
qemu-img resize -q -f raw disk.img 8G

step "Booting: $(cat cmdline.txt)"
qemu-system-aarch64 -M raspi3b -m 1G \
  -kernel kernel8.img -dtb bcm2710-rpi-3-b.dtb -initrd initramfs8 \
  -append "$(cat cmdline.txt)" \
  -drive file=disk.img,if=sd,format=raw \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$APP_PORT-:8080" \
  -device usb-net,netdev=net0 \
  -display none -monitor none -serial file:console.log &
QEMU_PID=$!
trap 'kill $QEMU_PID 2>/dev/null || true' EXIT

SSH=(ssh -i id_test -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o LogLevel=ERROR "$DEVICE_USER@127.0.0.1")
dev() { "${SSH[@]}" "$@"; }

deadline=$((SECONDS + BOOT_TIMEOUT))
until dev true 2>/dev/null; do
  kill -0 "$QEMU_PID" 2>/dev/null || { tail -50 console.log; fail "QEMU exited"; }
  [ "$SECONDS" -lt "$deadline" ] || { tail -50 console.log; fail "no ssh after ${BOOT_TIMEOUT}s"; }
  sleep 15
done
step "ssh up after ${SECONDS}s"

# Wait for boot to settle. "degraded" is reported, not fatal: some Pi hardware
# services can't work under emulation.
state=$(dev 'timeout 600 systemctl is-system-running --wait' || true)
step "System state: $state"
dev 'systemctl --failed --no-legend' || true
dev 'cloud-init status --wait --long' || true

FAILED=0
check() {
  local desc=$1; shift
  if out=$(dev "$@" 2>&1); then
    echo "PASS  $desc${out:+ ($(echo "$out" | tail -1))}"
  else
    echo "FAIL  $desc"; echo "$out" | sed 's/^/      /'; FAILED=1
  fi
}

check "app unit active" 'for i in $(seq 60); do systemctl is-active --quiet myapp.service && exit 0; sleep 5; done; systemctl status myapp.service --no-pager; exit 1'
check "app container healthy" 'test "$(sudo podman inspect -f "{{.State.Health.Status}}" myapp)" = healthy && echo healthy'
check "app runs the preloaded digest" '. /etc/pi-factory-release; test "$(sudo podman inspect -f "{{.ImageDigest}}" myapp)" = "$APP_DIGEST" && echo "$APP_DIGEST"'
check "auto-update timer active" 'systemctl is-active podman-auto-update.timer'
check "auto-update can reach the registry" 'sudo podman auto-update --dry-run --format "{{.Unit}} {{.Image}} updated={{.Updated}}" | grep myapp.service'
check "cloud-init finished without errors" 'cloud-init status | grep -qx "status: done" && echo done'
check "unique machine-id generated" 'id=$(cat /etc/machine-id); test -n "$id" && test "$id" != uninitialized && echo "$id"'
check "ssh host keys generated on device" 'ls /etc/ssh/ssh_host_ed25519_key.pub'
check "rootfs grown to the SD card" 'size=$(findmnt -bno SIZE /); test "$size" -gt 6000000000 && echo "$size bytes"'
check "hostname" "test \"\$(hostname)\" = $DEVICE_HOSTNAME && hostname"
check "first-boot wizard disabled" '! systemctl is-enabled --quiet userconfig.service && echo disabled'
check "ssh password auth disabled" 'sudo sshd -T | grep -x "passwordauthentication no"'
check "image release info" 'cat /etc/pi-factory-release'

if body=$(curl -fsS --max-time 10 "http://127.0.0.1:$APP_PORT/"); then
  echo "PASS  app reachable from outside ($body)"
else
  echo "FAIL  app reachable from outside"; FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  dev 'sudo journalctl -b --no-pager' > journal.log 2>&1 || true
  fail "boot test failed; see console.log and journal.log in $WORK"
fi
step "All checks passed"
