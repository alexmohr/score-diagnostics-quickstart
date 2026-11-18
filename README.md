# S-CORE diagnostics quickstart

Eclipse S-CORE with the diagnostics stack (OpenSOVD gateway and classic diagnostic adapter), built for Raspberry Pi and for a QEMU VM.

## Layout

| Path | What it is |
|---|---|
| `reference_integration/` | S-CORE integration. Submodule, pinned to a commit of [PR #482](https://github.com/eclipse-score/reference_integration/pull/482) (draft), which deploys the diagnostics with the platform. |
| `inc_diagnostics/` | Diagnostics stack. Submodule, pinned to a commit of [PR #70](https://github.com/eclipse-score/inc_diagnostics/pull/70) (draft), which makes it consumable by other Bazel modules. |
| `score/` | Docs and process repo. Nothing to build. |
| `dev.sh` | The three build and run commands (below). |
| `ecu-sim.sh` | Starts the CDA's ECU simulator and tests the built CDA against it (below). |

Clone with `git clone --recurse-submodules`. The submodules are pinned to commits, never to a branch, and the pins decide what gets built. Update a pin by checking out the new commit in the submodule and committing it here.

## Commands

```sh
./dev.sh build-pi     # S-CORE image for the Raspberry Pi 4B -> out/score-image-rpi4b.wic (flash it to an SD card)
./dev.sh build-qemu   # QEMU image (EB corbos Linux for Safety Applications, aarch64), ~30 min the first time
./dev.sh run-qemu     # boot it as a host on the Docker network of the simulator; ssh root@172.42.1.100 (no password)
./dev.sh run-pi       # boot the Pi image of build-pi in QEMU, the same way, at 172.42.1.101
```

## Booting the Pi image in QEMU

`./dev.sh run-pi` boots `out/score-image-rpi4b.wic` (run `./dev.sh build-pi` first) in QEMU, the same way as `run-qemu`: as a host on the Docker network `score-ecu-sim`, at `172.42.1.101`, with nothing published on the host. QEMU boots a copy of the image, with the static address of the Pi image replaced by that one; the `.wic` in `out/` stays as it is, ready to flash.

QEMU cannot run the kernel of the Pi image: its `raspi4b` machine emulates no Ethernet, and the Pi kernel does not get the emulated SD card working (`mmc1: Timeout waiting for hardware interrupt`). The VM therefore boots the kernel of the EB corbos QEMU image (`//images/ebclfsa_aarch64/build:extract-fastdev-image`) on the `virt` machine, with the root file system on the second partition of the Pi image (`root=/dev/vda2`). That kernel loads `virtio_net` and `bridge` as modules, which the Pi image does not have (it has those of the Pi kernel), so `qemu-sim-net.sh` copies `/lib/modules/<version>` of the QEMU image into the copy of the disk as well. Everything in user space is that of the Pi image: `ebclfsa-cflinit`, the crinit tasks, netifd and its network configuration, and the diagnostics service with the launch manager, the CDA and the gateway. What depends on the Pi kernel or the Pi hardware (drivers, `eth0` of the Pi, no RTC) is not covered.

The console of the VM shows the kernel and crinit messages but has no login (the Pi image runs its getty on `ttyS0` and `tty1`, the VM's console is `ttyAMA0`). Log in over ssh (no password) from a container on the network:

```sh
docker run --rm -it --network score-ecu-sim alpine sh -c 'apk add -q openssh-client && ssh -o StrictHostKeyChecking=no root@172.42.1.101'
```

The VM is slow without KVM: the diagnostics service is usually up a few minutes after the kernel starts. Stop the VM with `Ctrl-A x` in its console, or by stopping its container.

## Reaching the gateway

The gateway (OpenSOVD, SOVD over HTTP) listens on port **7690** of the address of the system, under `/sovd/v1`. The CDA behind it listens on the loopback address of the system only (port 20002) and is not reachable from outside.

| System | Gateway |
|---|---|
| Raspberry Pi | `http://192.168.7.2:7690/sovd/v1` (or the `SCORE_PI_ADDRESS` it was built with) |
| `./dev.sh run-pi` | `http://172.42.1.101:7690/sovd/v1` |
| `./dev.sh run-qemu` | `http://172.42.1.100:7690/sovd/v1` |

The gateway has no `/authorize` yet. Listing apps and components works without a token; reading data from an ECU is sent with a fixed development token (the one in `ecu-sim.sh`):

```sh
TOKEN=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0IiwiZXhwIjoyMDAwMDAwMDAwfQ.Q0IP5df7FxVEvVDF2v6soF8uh-j_qA-D_tgYTb3ur3g

# The Raspberry Pi, from a machine with an address in 192.168.7.0/24
curl -s http://192.168.7.2:7690/sovd/v1/apps
curl -s http://192.168.7.2:7690/sovd/v1/components
curl -s http://192.168.7.2:7690/sovd/v1/components/flxc1000/data/VINDataIdentifier -H "Authorization: Bearer $TOKEN"
```

The VMs are only on the Docker network, which the host has no route to with Docker Desktop. Run the client on that network:

```sh
docker run --rm --network score-ecu-sim curlimages/curl -s http://172.42.1.101:7690/sovd/v1/apps
docker run --rm --network score-ecu-sim curlimages/curl -s http://172.42.1.101:7690/sovd/v1/components
docker run --rm --network score-ecu-sim curlimages/curl -s http://172.42.1.101:7690/sovd/v1/components/flxc1000/data/VINDataIdentifier -H "Authorization: Bearer $TOKEN"
# {"id":"vindataidentifier","data":{"VIN":"SCEDT26T8BD005261"}}
```

The components are the ECUs that the CDA has found by DoIP broadcast: with `./ecu-sim.sh up` running before the VM boots, the simulated ECUs (for example `flxc1000`). A real Pi only finds ECUs on its own network.

The diagnostics end up in `/usr/bin/diagnostics/` (`opensovd-gateway`, `opensovd-cda`). The showcase `Diagnostics Stack` (`/showcases/data/diagnostics`) starts them with the launch manager.

```sh
./ecu-sim.sh up        # build and start the CDA's ECU simulator (Docker network score-ecu-sim)
./ecu-sim.sh test-vm   # with run-qemu running: start the stack in the VM, read the VIN of ECU flxc1000 through its gateway
./ecu-sim.sh test      # the same with the packages of build-pi in containers, without the QEMU image
./ecu-sim.sh down
```

The simulator, its ECU databases and the ECU settings come from the CDA commit that `inc_diagnostics` pins. The VM of `run-qemu` is a host on the simulator's network at `172.42.1.100`: nothing of it is published on the host, the gateway listens on that address (port 7690) and the CDA only on the loopback address of the VM. `test` runs the aarch64 binaries natively in arm64 containers, so it needs `./dev.sh build-pi` first. The gateway has no `/authorize` yet, so the tests send a fixed development token.

The Pi image is built like the QEMU image: the EB corbos toolkit image for the Raspberry Pi 4B with the platform, the showcases and the diagnostics service deployed in it (`//images/ebclfsa_rpi4b:image` in `reference_integration`), so it starts the stack at boot as well. It is for integration tests, not production: root can log in over ssh without a password.

## Network of the Pi image

The Pi image has a static address and no DHCP client or link-local fallback. The base image of EB corbos configures it in `/etc/config/network` (netifd format), and `reference_integration` does not change that:

```
config device
    option type  bridge
    option name  br0
    list ports  eth0
    option ipv6  0

config interface lan
    option device   br0
    option proto    static
    option ipaddr   192.168.7.2/24
    option gateway  192.168.7.1
    list dns        8.8.8.8
```

- To reach the Pi, give your machine an address in `192.168.7.0/24` (for example `192.168.7.1/24`) on the interface it is connected to, then `ssh root@192.168.7.2` (no password). The gateway listens on that address, port 7690.
- There is no `169.254.x.x` address, and IPv6 is disabled (`option ipv6 0`), so there is no `fe80::` address either.
- To change the address at build time, set `SCORE_PI_ADDRESS` (with prefix length), `SCORE_PI_GATEWAY` (empty for none) and `SCORE_PI_DNS` (comma separated) when you run `dev.sh` or Bazel, for example `SCORE_PI_ADDRESS=10.0.0.20/24 SCORE_PI_GATEWAY=10.0.0.1 ./dev.sh build-pi`. A change rebuilds the image, not the platform. The same variables set the address of the Raspberry Pi OS image of `reference_integration` (`//images/rpios_rpi4b:image`), which uses a NetworkManager profile instead.
- To change it afterwards, edit `/etc/config/network` over ssh on the running Pi, or in the root partition (the second partition) of the `.wic` file before flashing. `qemu-sim-net.sh` does the latter with `debugfs` for the QEMU image (`172.42.1.100/16`).
- The image has `netifd`, BusyBox `udhcpc` and `systemd-networkd`, but no `avahi-autoipd`, and `/lib/netifd` holds no protocol scripts. Whether `option proto dhcp` or a link-local fallback works was not tried.
- The diagnostics service waits for a network address before it starts the stack, so it starts with the static address as well.

The configuration is documented in `images/network/README.md` of `reference_integration`. That change is not in PR #482 yet.

## How it builds

The hermetic toolchains only run on x86_64 Linux, so `dev.sh` builds in the official devcontainer as `linux/amd64` (emulated, so slow on arm64 hosts), extended with the aarch64 glibc headers that the Pi build needs. It requires Docker Desktop with at least 8 GB RAM.

`reference_integration` cannot be checked out completely on a case-insensitive file system (a `BUILD` file and a `build/` directory share a name). `dev.sh` therefore builds from a clone in the Docker volume `score-ref-int` that it keeps in sync with the submodule pin. Bazel's cache is in the volume `score-bazel-cache`.

## Status

- Verified: `build-pi` and `run-pi` (with the simulator: the diagnostics service starts at boot, the gateway at `172.42.1.101:7690` lists the simulated ECUs and reads the VIN of `flxc1000`, the CDA is not reachable directly). Not verified on a real Raspberry Pi.
- Verified: `build-pi`, `build-qemu`, `run-qemu` and `./ecu-sim.sh test-vm`: the gateway and the CDA in the VM read the VIN of a simulated ECU, and the CDA is not reachable directly.
- Not done: nothing starts the stack when the VM boots (the showcase does, `test-vm` starts it over ssh), and the gateway has no authentication.
- QEMU runs without KVM here, so the VM needs several minutes to boot, and a build next to it can run out of memory.

## License

Apache License 2.0, see [LICENSE](LICENSE). The submodules have their own licenses.
