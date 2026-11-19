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
./dev.sh run-pi       # build the Pi image with the address 172.42.1.101 and boot it in QEMU, the same way
```

## How the test setup works

Everything runs in Docker. The VM of `run-pi` (or `run-qemu`) and the ECU simulator are two hosts on one Docker network, `score-ecu-sim` (`172.42.0.0/16`), so the diagnostics stack in the VM talks to the simulated ECUs the way it would talk to real ones.

```
 macOS
 │  ./dev.sh run-pi, ./ecu-sim.sh up
 │  127.0.0.1:8181 ──────────────┐ (published: simulator control API only)
 │                               │
 └─ Docker Desktop (hidden Linux VM)
    │
    │  Docker network score-ecu-sim  172.42.0.0/16
    │  ════════╤═════════════════════╤═══════════════════════╤═════════
    │          │                     │                       │
    │  ┌───────┴────────┐  ┌─────────┴───────────────┐  ┌────┴──────────────┐
    │  │ score-ecu-sim  │  │ run-pi container        │  │ throwaway client  │
    │  │ (container)    │  │                         │  │ curl / ssh        │
    │  │                │  │  eth0 ─┐                │  │ docker run --rm   │
    │  │ simulated ECUs │  │        br0 ── tap0      │  │ --network ...     │
    │  │ flxc1000,      │  │                │        │  └───────────────────┘
    │  │ hovr4000, ...  │  │  ┌─────────────┴─────┐  │
    │  │ DoIP :13400    │  │  │ QEMU VM (aarch64) │  │
    │  │ control :8181  │  │  │ 172.42.1.101      │  │
    │  └────────────────┘  │  │                   │  │
    │                      │  │ gateway  :7690 ◄──┼──┼── SOVD/HTTP from clients
    │                      │  │   │ (VM address)  │  │
    │                      │  │   ▼               │  │
    │                      │  │ CDA 127.0.0.1:20002  │
    │                      │  │   │ DoIP ─────────┼──┼──► ECUs on the network
    │                      │  │ sshd :22          │  │
    │                      │  └───────────────────┘  │
    │                      └─────────────────────────┘
```

### The parts

- **ECU simulator** (`./ecu-sim.sh up`): the test simulator of the CDA, built at the CDA commit that `inc_diagnostics` pins. It runs virtual ECUs that speak DoIP (ISO 13400) and UDS (ISO 14229). Its control API on port 8181 is the only thing published on the host.
- **The `run-pi` container**: the S-CORE devcontainer, used here only to run QEMU. `qemu-sim-net.sh` bridges the container's `eth0` with the VM's tap device, so the VM is a host of its own on the Docker network, not hidden behind the container.
- **The VM**: the EB corbos Pi image, the one that is flashed to the Pi, built with the address `172.42.1.101/16` (so the network, the CDA and the gateway use it), with the modules of the QEMU kernel added to the copy of its disk that QEMU boots. It boots the EB corbos QEMU kernel, because QEMU cannot run the Pi kernel (see below). Everything in user space is the Pi image. At boot, crinit runs the `diagnostics` task, which starts the S-CORE launch manager. The launch manager starts and supervises the CDA and then the gateway.

### A request, end to end

`GET /sovd/v1/components/flxc1000/data/VINDataIdentifier`:

1. The client, a container on the network, sends it to the **gateway** at `172.42.1.101:7690`. The gateway is the SOVD server (ISO 17978) and the only diagnostics port that is open.
2. The gateway forwards what it does not serve itself to the **CDA** at `127.0.0.1:20002`. The CDA is only reachable inside the VM, so clients have to use the gateway.
3. The CDA looks up the VIN in the ECU database (`.mdd` files) and turns it into a UDS request (ReadDataByIdentifier).
4. The CDA sends that request over DoIP to the simulated ECU.
5. The ECU answers, the CDA decodes the bytes into JSON, and the gateway returns it.

### How the CDA finds the ECUs

When the CDA starts, it broadcasts a DoIP vehicle identification request on the network, once. The simulated ECUs answer with their addresses. That is why the VM has to be on the same network as the simulator, and why the simulator has to run before the VM boots: after restarting the simulator, reboot the VM as well.

### Why it is built like this

- Nothing of the VM is forwarded to the host. The VM behaves like a real Pi on a vehicle network: it has an address of its own, is reached over the network, and does not expose the CDA. The host has no route to Docker networks with Docker Desktop, which is why clients run in a container on the network.
- On the real Pi only the network changes: the Pi is on your Ethernet at `192.168.7.2`, and the CDA finds the DoIP ECUs on that network.

## Booting the Pi image in QEMU

`./dev.sh run-pi` builds the EB corbos Pi image (`//images/ebclfsa_rpi4b:image`) with `SCORE_PI_ADDRESS=172.42.1.101/16` and the gateway of the Docker network, and boots it in QEMU the same way as `run-qemu`: as a host on the Docker network `score-ecu-sim`, at `172.42.1.101`, with nothing published on the host. The image is built with that address rather than changed afterwards, because the address of the gateway is in the binary launch manager configuration (see [Network of the Pi image](#network-of-the-pi-image)). The image stays in Bazel's output; `out/score-image-rpi4b.wic` of `build-pi` is not touched. The next `build-pi` rebuilds the image with its own address.

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
- The diagnostics use the address of the image as well, not the `0.0.0.0` of the generic showcase. The Pi images replace two files of the showcase, built from `SCORE_PI_ADDRESS`:
  - `/showcases/data/diagnostics/opensovd-cda.toml`: `tester_address` and `tester_subnet` of the CDA (for example `192.168.7.2`, `255.255.255.0`). The CDA sends its DoIP vehicle identification from that address. With `0.0.0.0` it needs a route to send it and stops with `Failed to send VIR: ... Network is unreachable` without one, for example with a link-local address and no gateway.
  - `/showcases/data/diagnostics/etc/launch_manager_config.bin`: `SCORE_GATEWAY_ADDRESS` of the gateway (for example `192.168.7.2:7690`), so the gateway listens on the address of the image only.
- If you change the address on the running Pi, change `tester_address` and `tester_subnet` as well. The address of the gateway is in the binary launch manager configuration and needs a new build of the image.

The configuration is documented in `images/network/README.md` of `reference_integration`. That change is not in PR #482 yet.

## How it builds

The hermetic toolchains only run on x86_64 Linux, so `dev.sh` builds in the official devcontainer as `linux/amd64` (emulated, so slow on arm64 hosts), extended with the aarch64 glibc headers that the Pi build needs. It requires Docker Desktop with at least 8 GB RAM.

`reference_integration` cannot be checked out completely on a case-insensitive file system (a `BUILD` file and a `build/` directory share a name). `dev.sh` therefore builds from a clone in the Docker volume `score-ref-int` that it keeps in sync with the submodule pin. Bazel's cache is in the volume `score-bazel-cache`.

## Status

- Verified: `build-pi` and `run-pi` (with the simulator: the diagnostics service starts at boot, the gateway listens on `172.42.1.101:7690` only, lists the simulated ECUs and reads the VIN of `flxc1000`, also without a default route; the CDA is not reachable directly). Not verified on a real Raspberry Pi. The Raspberry Pi OS image was only analyzed, not built, after the diagnostics addresses were added.
- Verified: `build-pi`, `build-qemu`, `run-qemu` and `./ecu-sim.sh test-vm`: the gateway and the CDA in the VM read the VIN of a simulated ECU, and the CDA is not reachable directly.
- Not done: nothing starts the stack when the VM boots (the showcase does, `test-vm` starts it over ssh), and the gateway has no authentication.
- QEMU runs without KVM here, so the VM needs several minutes to boot, and a build next to it can run out of memory.

## License

Apache License 2.0, see [LICENSE](LICENSE). The submodules have their own licenses.
