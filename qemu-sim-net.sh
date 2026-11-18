#!/usr/bin/env bash
# Runs inside the devcontainer (started by ./dev.sh run-qemu): boots the EB corbos image with QEMU
# as a host on the Docker network of the ECU simulator, so that the classic diagnostic adapter in
# the VM finds the simulated ECUs by DoIP broadcast.
#
# The container's eth0 and a tap device of the VM are joined in a bridge. The image configures its
# network statically (192.168.7.2/24, for QEMU's user networking), so the address on the simulator's
# network (VM_IP) is written into the copy of the disk that QEMU uses: the VM has it from the first
# second, which matters because the CDA broadcasts once, from the address that the host picks when
# it starts. Nothing of the VM is forwarded or published: it is reached by that address. The VM runs
# the same kernel and disk as "bazel run //images/ebclfsa_aarch64:run", with the same options except
# for the network.
#
# "qemu-sim-net.sh pi" (./dev.sh run-pi) boots the Raspberry Pi image of ./dev.sh build-pi
# (/out/score-image-rpi4b.wic) the same way, at 172.42.1.101. QEMU cannot run the kernel of the Pi
# image: its raspi4b machine has no Ethernet and does not get the SD card of this image working. The
# VM therefore boots the kernel of the QEMU image with the disk of the Pi image, root file system on
# its second partition. Everything in user space is that of the Pi image: init, crinit tasks, netifd,
# the diagnostics service. What depends on the Pi kernel or hardware is not covered.
set -euo pipefail

MODE="${1:-qemu}"
VM_MAC=52:54:00:12:34:56
cd /work/reference_integration

# kernel_and_image <label>: sets kernel and image to the vmlinux and .wic files that <label> builds.
kernel_and_image() {
  local files
  bazel build --config=eb-aarch64 "$1"
  files="$(bazel cquery --config=eb-aarch64 --output=files "$1")"
  # cquery prints bazel-out/<configuration>/bin/<path>, which bazel-bin points to.
  kernel="bazel-bin/$(grep 'vmlinux$' <<<"$files" | sed 's#^bazel-out/[^/]*/bin/##')"
  image="bazel-bin/$(grep '\.wic$' <<<"$files" | sed 's#^bazel-out/[^/]*/bin/##')"
}

case "$MODE" in
  qemu)
    VM_IP="${VM_IP:-172.42.1.100}"
    kernel_and_image //images/ebclfsa_aarch64:image
    root_partition=1
    ;;
  pi)
    VM_IP="${VM_IP:-172.42.1.101}"
    # Only the kernel of the toolkit's QEMU image, not the deployed QEMU image.
    kernel_and_image //images/ebclfsa_aarch64/build:extract-fastdev-image
    qemu_disk="$image"
    image=/out/score-image-rpi4b.wic
    root_partition=2
    ;;
  *) echo "usage: qemu-sim-net.sh [qemu|pi]" >&2; exit 2 ;;
esac
[[ -f "$kernel" && -f "$image" ]] || { echo "kernel or image not found: $kernel $image" >&2; exit 1; }
# QEMU writes to the disk, the build output stays as it is.
cp --sparse=always "$image" /tmp/vm.wic

# partition <disk> <number>: the partition of an MBR disk, as debugfs takes it.
partition() {
  echo "$1?offset=$(python3 -c '
import struct, sys
entry = 446 + 16 * (int(sys.argv[2]) - 1)
print(struct.unpack("<I", open(sys.argv[1], "rb").read(512)[entry + 8:entry + 12])[0] * 512)' "$1" "$2")"
}

gateway="$(ip route | awk '/^default/ {print $3}')"
rootfs="$(partition /tmp/vm.wic "$root_partition")"

# The Pi image has the modules of the Pi kernel only, the kernel of the QEMU image loads virtio_net
# and bridge as modules: its modules are copied from the QEMU image into the copy of the disk.
if [[ "$MODE" == pi ]]; then
  qemu_rootfs="$(partition "$qemu_disk" 1)"
  kver="$(debugfs -R "ls /lib/modules" "$qemu_rootfs" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '(' | head -1)"
  [[ -n "$kver" ]] || { echo "no modules in the QEMU image" >&2; exit 1; }
  rm -rf /tmp/modules && mkdir -p /tmp/modules
  debugfs -R "rdump /lib/modules/$kver /tmp/modules" "$qemu_rootfs" >/dev/null 2>&1
  [[ -d "/tmp/modules/$kver" ]] || { echo "cannot read the modules of the QEMU image" >&2; exit 1; }
  (
    cd /tmp/modules
    find "$kver" -mindepth 0 -type d | sort | sed 's#^#mkdir /lib/modules/#'
    find "$kver" -type f | sed 's#.*#write /tmp/modules/& /lib/modules/&#'
    find "$kver" -type l | while read -r l; do echo "symlink /lib/modules/$l $(readlink "$l")"; done
  ) > /tmp/modules.debugfs
  debugfs -w -f /tmp/modules.debugfs "$rootfs" >/dev/null 2>&1
  debugfs -R "stat /lib/modules/$kver/modules.dep" "$rootfs" 2>/dev/null | grep -q 'Type: regular' \
    || { echo "the modules of the QEMU kernel were not written" >&2; exit 1; }
  echo "modules of the QEMU kernel $kver copied into the disk of the VM"
fi
# The static address of the image, whatever it was built with, becomes VM_IP; the loopback stays.
debugfs -R "cat /etc/config/network" "$rootfs" 2>/dev/null \
  | sed -E -e "/127\.0\.0\.1/! s#(option[[:space:]]+ipaddr[[:space:]]+)[^[:space:]]+#\1$VM_IP/16#" \
           -e "s#(option[[:space:]]+gateway[[:space:]]+)[^[:space:]]+#\1$gateway#" > /tmp/vm-network
grep -q "$VM_IP/16" /tmp/vm-network || { echo "cannot set the address of the VM in /etc/config/network" >&2; exit 1; }
debugfs -w -R "rm /etc/config/network" "$rootfs" >/dev/null 2>&1
debugfs -w -R "write /tmp/vm-network /etc/config/network" "$rootfs" >/dev/null 2>&1
debugfs -R "cat /etc/config/network" "$rootfs" 2>/dev/null | grep -q "$VM_IP/16" || { echo "the address of the VM was not written" >&2; exit 1; }

addr="$(ip -4 -o addr show dev eth0 | awk '{print $4}')"
ip link add br0 type bridge
ip link set br0 up
ip tuntap add tap0 mode tap
ip link set tap0 master br0 up
ip addr flush dev eth0
ip link set eth0 master br0
ip addr add "$addr" dev br0
ip route add default via "$gateway"
# The Docker network reflects flooded frames to the sender, so the bridge would learn the MAC of
# the VM on eth0 and send its traffic out of the container instead of to tap0.
bridge fdb replace "$VM_MAC" dev tap0 master static sticky
bridge link set dev eth0 learning off

echo "VM address $VM_IP on the network of the container ($addr)"
exec qemu-system-aarch64 \
  -m 4G -machine virt,virtualization=true,gic-version=3 -cpu cortex-a53 -smp 8 \
  -kernel "$kernel" \
  -append "root=/dev/vda$root_partition sdk_enable lisa_syscall_whitelist=2026 rw sharedmem.enable_sharedmem=0 init=/usr/bin/ebclfsa-cflinit" \
  -device virtio-blk-device,drive=vd0 -drive if=none,format=raw,file=/tmp/vm.wic,id=vd0 \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no -device "virtio-net-device,netdev=net0,mac=$VM_MAC" \
  -nographic -chardev stdio,id=char0,signal=on,mux=on -mon chardev=char0,mode=readline -serial chardev:char0
