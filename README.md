# pi-factory-image

Proof-of-concept CI/CD for shipping Raspberry Pi devices: take a stock
Raspberry Pi OS image, preinstall software, preconfigure the system, preload a
Podman container, and publish one flashable image for the factory. After shipping, the container updates itself from the registry, and a
failed update rolls back.

```
app/ ──(app.yml)──> ghcr.io/<repo>/app:stable ─────────────┐ hourly pull
                                    │                       │ (podman auto-update,
                                    │ preloaded at build    │  rollback on failure)
os/  ──(os-image.yml)──> build ──> release ──> factory ──> device
```

## Pipelines

| Workflow | Trigger | Result |
|---|---|---|
| `app.yml` | push to `main` touching `app/` | `app:edge`, `app:sha-…` |
| | tag `app-vX.Y.Z` | `app:X.Y.Z`, `app:stable`: **every device picks it up within ~1h** |
| `os-image.yml` | push/PR touching `os/` | image built, kept 30 days as a workflow artifact |
| | tag `os-vX.Y.Z` | the same, plus a GitHub Release with the factory files |
| | manual dispatch | choose which app tag to preload (default `stable`) |

Both run on GitHub's native arm64 runners (`ubuntu-24.04-arm`, free for public
repos), so the chroot and the container build need no emulation.

### What the OS build does (`os/build.sh`, `os/customize.sh`)

1. Downloads the pinned base image (`os/config.env`) and checks it against the
   pinned SHA-256. The base image is cached between runs.
2. Grows the root partition by `IMAGE_GROW`. The device still expands it to
   the full SD card on first boot.
3. In an arm64 chroot: installs `os/packages.txt` (Podman 5.4 from Debian
   trixie), then renames the stock `pi` user to `DEVICE_USER` with a locked
   password and disables the interactive first-boot wizard. Enables ssh
   (key-only) and the auto-update timer, and sets hostname and timezone.
4. Copies `os/overlay/` onto the rootfs: the Quadlet unit, the update
   schedule, sshd hardening, and cloud-init settings.
5. Pulls the app image into the image's container storage, so first boot works
   offline. It's pulled from the registry rather than `podman load`ed, so the
   stored digest matches the registry's.
6. Validates the Quadlet unit with the generator's `--dryrun`.
7. Checks that the image is still in "first boot" state: `machine-id` is
   `uninitialized`, there are no ssh host keys, and cloud-init hasn't run.
   That way every device gets its own identity.
8. Writes `/etc/pi-factory-release` (version, commit, base image, app digest),
   then trims, compresses, and creates the bmap, checksums and manifest.

### Checking an image on a device

There's no automated boot test; check each new image on a real Pi before
tagging a release. Flash it, add your key to `user-data` on the boot partition
if `DEVICE_SSH_AUTHORIZED_KEYS` isn't set, boot with network, then:

```sh
ssh admin@pi-factory.local
systemctl is-active myapp.service                 # active
sudo podman ps                                    # myapp, (healthy)
curl http://localhost:8080/                       # hello from myapp <version>
cat /etc/pi-factory-release                       # versions and app digest
sudo podman auto-update --dry-run                 # myapp.service ... false
cloud-init status                                 # status: done
df -h /                                           # grown to the SD card size
```

## Factory handoff

An `os-vX.Y.Z` release contains:

| File | Purpose |
|---|---|
| `pi-factory-X.Y.Z.img.xz` | the image |
| `pi-factory-X.Y.Z.img.bmap` | block map: flashing skips empty blocks (`bmaptool copy`) |
| `pi-factory-X.Y.Z.sha256` | checksums for the image and the bmap |
| `pi-factory-X.Y.Z.manifest.txt` | release info and the full package list (traceability) |

Flash with `bmaptool copy pi-factory-X.Y.Z.img.xz /dev/sdX`, Raspberry Pi
Imager ("Use custom"), or any SD/eMMC duplicator. The image is generic: every
device generates its own identity (machine-id, ssh host keys) on first boot.

## Updating devices in the field

- **App:** change `app/`, merge, then tag `app-vX.Y.Z`. Devices check
  `app:stable` hourly (randomized ±15 min, `podman-auto-update.timer`). They
  pull the new image and restart the unit. Because of `Notify=healthy`, the
  unit only counts as started once the healthcheck passes. If it doesn't,
  Podman rolls back to the previous image.
- **OS:** this pipeline only produces factory images. It does not update the
  OS of devices that are already deployed (see below).

## Configuration

- `os/config.env`: base image URL and checksum, rootfs growth, hostname, user, timezone
- `os/packages.txt`: packages to preinstall
- `os/overlay/`: files copied as-is onto the rootfs (`@APP_IMAGE@` and
  `@DEVICE_USER@` are substituted)
- `os/boot/user-data`: cloud-init config on the FAT boot partition, applied
  once per device. You can edit it after flashing if a batch needs it.
- Repository variable `DEVICE_SSH_AUTHORIZED_KEYS`: public keys (one per line)
  for `DEVICE_USER`. Without it, devices have no ssh access.

### Building locally

You need an arm64 Linux host with root, `bmap-tools`, `e2fsprogs`, `xz-utils`:

```sh
. os/config.env && curl -fLo base.img.xz "$BASE_URL"
sudo APP_IMAGE=ghcr.io/malyshevhen/pi-factory-image/app:stable os/build.sh base.img.xz dist dev
```

## Before production

This is a blueprint. These are the gaps to close before real devices ship:

- **OS updates for deployed devices.** Use A/B root partitions with
  [RAUC](https://rauc.io/), [Mender](https://mender.io/) or
  [SWUpdate](https://swupdate.org/), or at least scheduled
  `unattended-upgrades`. The OS image should then be built for that layout.
- **Trust in the update channel.** Sign app images (cosign/sigstore) and make
  devices verify them (`/etc/containers/policy.json`). If the registry is
  private, provision registry credentials to devices.
- **Staged rollouts.** Use per-cohort tags (`canary`, `stable`) instead of one
  fleet-wide `stable`, and promote between them.
- **Device identity.** Give each device a unique hostname, device certificate
  or token, and register it with your fleet backend. mDNS name collisions on
  one network are a real issue with a shared hostname.
- **Supply chain.** Pin actions to commit SHAs (Dependabot keeps them fresh),
  pin the app base image by digest, and generate an SBOM for the OS image.
- **Hardening.** Read-only root or overlayfs, a hardware watchdog, persistent
  journald limits, firewall, and possibly secure boot (Pi 5 / CM5).
- **Automated boot test.** Add a hardware-in-the-loop job: a self-hosted
  runner with a Pi attached (USB SD-mux or netboot), flashing every build and
  running the checks above. QEMU's `raspi3b` emulation was tried and dropped:
  the kernel boots and the app comes up, but the watchdog, console and USB
  network need workarounds, and DHCP over the emulated NIC never worked.
