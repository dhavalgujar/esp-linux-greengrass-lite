# Evaluation: Greengrass Lite with systemd on 16 MiB

The configuration that was measured and rejected in favour of the
systemd-free build: upstream Greengrass Lite with its systemd service
model, a Buildroot-built glibc toolchain, zram swap
(`vm.swappiness=100`), no ifupdown, and an NFS root. It includes the
instrument used to measure it: `s31-memlog` samples memory, page refaults
and blocked tasks every 10 s into `/var/log/s31-memlog.txt` (on the NFS
root, so it can be read from the workstation even when the board is
unreachable).

Result: it builds and boots, but thrashes. See `../results.md`.

To reproduce (alongside the main image; it uses its own output directory
and NFS root):

```sh
export S31_DEFCONFIG=$PWD/development_tools/systemd-evaluation/esp32s31_fcb_greengrass_systemd_defconfig
export S31_NFS_ROOT=systemd-eval
S31_NFS_SERVER=<workstation-ip> scripts/build.sh
scripts/nfs-deploy.sh <thing-name>
scripts/flash.sh <serial-port> <chip-mac>
cat ../nfs/systemd-eval/var/log/s31-memlog.txt
```
