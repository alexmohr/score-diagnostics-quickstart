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
set -euo pipefail

VM_IP="${VM_IP:-172.42.1.100}"
VM_MAC=52:54:00:12:34:56
cd /work/reference_integration

bazel build --config=eb-aarch64 //images/ebclfsa_aarch64:image
files="$(bazel cquery --config=eb-aarch64 --output=files //images/ebclfsa_aarch64:image)"
# cquery prints bazel-out/<configuration>/bin/<path>, which bazel-bin points to.
kernel="bazel-bin/$(grep 'vmlinux$' <<<"$files" | sed 's#^bazel-out/[^/]*/bin/##')"
image="bazel-bin/$(grep '\.wic$' <<<"$files" | sed 's#^bazel-out/[^/]*/bin/##')"
[[ -f "$kernel" && -f "$image" ]] || { echo "kernel or image not found: $kernel $image" >&2; exit 1; }
# QEMU writes to the disk, the build output stays as it is.
cp --sparse=always "$image" /tmp/vm.wic

gateway="$(ip route | awk '/^default/ {print $3}')"
# The root file system is the first partition of the disk.
rootfs="/tmp/vm.wic?offset=$(python3 -c 'import struct,sys; m=open(sys.argv[1],"rb").read(512); print(struct.unpack("<I", m[454:458])[0]*512)' /tmp/vm.wic)"
debugfs -R "cat /etc/config/network" "$rootfs" 2>/dev/null \
  | sed -e "s#192.168.7.2/24#$VM_IP/16#" -e "s#192.168.7.1#$gateway#" > /tmp/vm-network
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
  -append "root=/dev/vda1 sdk_enable lisa_syscall_whitelist=2026 rw sharedmem.enable_sharedmem=0 init=/usr/bin/ebclfsa-cflinit" \
  -device virtio-blk-device,drive=vd0 -drive if=none,format=raw,file=/tmp/vm.wic,id=vd0 \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no -device "virtio-net-device,netdev=net0,mac=$VM_MAC" \
  -nographic -chardev stdio,id=char0,signal=on,mux=on -mon chardev=char0,mode=readline -serial chardev:char0
