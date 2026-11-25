# S-CORE diagnostics quickstart

Eclipse S-CORE with the diagnostics stack (OpenSOVD gateway and classic diagnostic adapter), built for Raspberry Pi and for a QEMU VM.

## Layout

| Path | What it is |
|---|---|
| `reference_integration/` | S-CORE integration. Submodule, pinned to a commit of [PR #482](https://github.com/eclipse-score/reference_integration/pull/482) (draft), which deploys the diagnostics with the platform. |
| `inc_diagnostics/` | Diagnostics stack. Submodule, pinned to a commit of [diagnostics main](https://github.com/eclipse-score/diagnostics). |
| `score/` | Docs and process repo. Nothing to build. |
| `dev.sh` | The three build and run commands (below). |
| `ecu-sim.sh` | Starts the CDA's ECU simulator and tests the built CDA against it (below). |

The submodules are pinned to commits, never to a branch, and the pins decide what gets built. On a case-sensitive file system, clone with `git clone --recurse-submodules`. On a case-insensitive file system, clone the root and initialize `inc_diagnostics` and `score` individually: the `reference_integration` host checkout is incomplete, so `dev.sh` builds it in a Docker volume instead.

## Commands

```sh
./dev.sh build-pi     # S-CORE image for the Raspberry Pi 4B -> out/score-image-rpi4b.wic (flash it to an SD card)
./dev.sh build-qemu   # QEMU image (EB corbos Linux for Safety Applications, aarch64), ~30 min the first time
./dev.sh run-qemu     # boot it as a host on the Docker network of the simulator; ssh root@172.42.1.100 (no password)
```

## How the test setup works

In the QEMU setup everything runs in Docker. The VM of `run-qemu` and the ECU simulator are two hosts on one Docker network, `score-ecu-sim` (`172.42.0.0/16`), so the diagnostics stack in the VM talks to the simulated ECUs the way it would talk to real ones. The physical Pi setup uses a native simulator instead, as described below.

```
 macOS
 │  ./dev.sh run-qemu, ./ecu-sim.sh up
 │  127.0.0.1:8181 ──────────────┐ (published: simulator control API only)
 │                               │
 └─ Docker Desktop (hidden Linux VM)
    │
    │  Docker network score-ecu-sim  172.42.0.0/16
    │  ════════╤═════════════════════╤═══════════════════════╤═════════
    │          │                     │                       │
    │  ┌───────┴────────┐  ┌─────────┴───────────────┐  ┌────┴──────────────┐
    │  │ score-ecu-sim  │  │ run-qemu container      │  │ throwaway client  │
    │  │ (container)    │  │                         │  │ curl / ssh        │
    │  │                │  │  eth0 ─┐                │  │ docker run --rm   │
    │  │ simulated ECUs │  │        br0 ── tap0      │  │ --network ...     │
    │  │ flxc1000,      │  │                │        │  └───────────────────┘
    │  │ hovr4000, ...  │  │  ┌─────────────┴─────┐  │
    │  │ DoIP :13400    │  │  │ QEMU VM (aarch64) │  │
    │  │ control :8181  │  │  │ 172.42.1.100      │  │
    │  └────────────────┘  │  │                   │  │
    │                      │  │ gateway  :7690 ◄──┼──┼── SOVD/HTTP from clients
    │                      │  │   │ (VM address)  │  │
    │                      │  │   ▼               │  │
    │                      │  │ CDA (Unix socket) │  │
    │                      │  │   │ DoIP ─────────┼──┼──► ECUs on the network
    │                      │  │ sshd :22          │  │
    │                      │  └───────────────────┘  │
    │                      └─────────────────────────┘
```

### The parts

- **ECU simulator** (`./ecu-sim.sh up`): the test simulator of the CDA, built at the CDA commit that `inc_diagnostics` pins. It runs virtual ECUs that speak DoIP (ISO 13400) and UDS (ISO 14229). Its control API on port 8181 is the only thing published on the host.
- **The `run-qemu` container**: the S-CORE devcontainer, used here only to run QEMU. `qemu-sim-net.sh` bridges the container's `eth0` with the VM's tap device, so the VM is a host of its own on the Docker network, not hidden behind the container.
- **The VM**: the EB corbos QEMU image (`//images/ebclfsa_aarch64:image`), with the address `172.42.1.100/16` written into the copy of its disk that QEMU boots. At boot, crinit runs the `diagnostics` task, which starts the S-CORE launch manager. The launch manager starts and supervises the CDA and then the gateway. The Pi images are not booted in QEMU: QEMU cannot run their kernels, and booting them with another kernel would mean changing the images.

### A request, end to end

`GET /sovd/v1/components/flxc1000/data/VINDataIdentifier`:

1. The client, a container on the network, sends it to the **gateway** at `172.42.1.100:7690`. The gateway is the SOVD server (ISO 17978) and the only diagnostics port that is open.
2. The gateway forwards what it does not serve itself to the **CDA** over the Unix domain socket `/run/opensovd-cda.sock`. The CDA has no TCP port, so clients have to use the gateway.
3. The CDA looks up the VIN in the ECU database (`.mdd` files) and turns it into a UDS request (ReadDataByIdentifier).
4. The CDA sends that request over DoIP to the simulated ECU.
5. The ECU answers, the CDA decodes the bytes into JSON, and the gateway returns it.

### How the CDA finds the ECUs

When the CDA starts, it broadcasts a DoIP vehicle identification request on the network, once. The simulated ECUs answer with their addresses. That is why the VM has to be on the same network as the simulator, and why the simulator has to run before the VM boots: after restarting the simulator, reboot the VM as well.

### Why it is built like this

- Nothing of the VM is forwarded to the host. The VM behaves like a real Pi on a vehicle network: it has an address of its own, is reached over the network, and does not expose the CDA. The host has no route to Docker networks with Docker Desktop, which is why clients run in a container on the network.
- On the real Pi only the network changes: the Pi is on your Ethernet at `192.168.7.2`, and the CDA finds the DoIP ECUs on that network.

## Reaching the gateway

The gateway (OpenSOVD, SOVD over HTTP) listens on port **7690** of the address of the system, under `/sovd/v1`. The CDA behind it listens on the Unix domain socket `/run/opensovd-cda.sock` only and is not reachable over the network.

| System | Gateway |
|---|---|
| Raspberry Pi | `http://192.168.7.2:7690/sovd/v1` (or the `SCORE_PI_ADDRESS` it was built with) |
| `./dev.sh run-qemu` | `http://172.42.1.100:7690/sovd/v1` |

The gateway's development mode issues a token from `POST /sovd/v1/authorize` (ISO 17978-3 §7.23.4). Apps, components and ECU data require it; `/sovd/version-info` is available without one. The example uses `jq` to extract the token.

**Development only:** the placeholder accepts any non-empty credentials and does not verify token signatures. It is not production authentication; see `inc_diagnostics/score/opensovd-core/README.md` for the external-issuer configuration.

```sh
# The Raspberry Pi, from a machine with an address in 192.168.7.0/24
ROOT_URL=http://192.168.7.2:7690/sovd
BASE=$ROOT_URL/v1
TOKEN=$(curl -fsS -H 'Content-Type: application/json' \
  --data '{"client_id":"tester","client_secret":"secret"}' "$BASE/authorize" | jq -er .access_token)
curl -fsS "$ROOT_URL/version-info"
curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/apps"
curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/components"
curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/components/flxc1000/data/VINDataIdentifier"
```

The VM is only on the Docker network, which the host has no route to with Docker Desktop. Run the client on that network:

```sh
BASE=http://172.42.1.100:7690/sovd/v1
TOKEN=$(docker run --rm --network score-ecu-sim curlimages/curl -fsS \
  -H 'Content-Type: application/json' --data '{"client_id":"tester","client_secret":"secret"}' \
  "$BASE/authorize" | jq -er .access_token)
docker run --rm --network score-ecu-sim curlimages/curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/apps"
docker run --rm --network score-ecu-sim curlimages/curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/components"
docker run --rm --network score-ecu-sim curlimages/curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/components/flxc1000/data/VINDataIdentifier"
# {"id":"vindataidentifier","data":{"VIN":"SCEDT26T8BD005261"}}
```

The components are the ECUs that the CDA has found by DoIP broadcast: with `./ecu-sim.sh up` running before the VM boots, the simulated ECUs (for example `flxc1000`). A real Pi only finds ECUs on its own network.

The diagnostics end up in `/usr/bin/diagnostics/` (`opensovd-gateway`, `opensovd-cda`). The showcase `Diagnostics Stack` (`/showcases/data/diagnostics`) starts them with the launch manager.

```sh
./ecu-sim.sh up        # build and start the CDA's ECU simulator (Docker network score-ecu-sim)
./ecu-sim.sh test-vm   # with run-qemu running: wait for the stack, read the VIN of ECU flxc1000 through its gateway
./ecu-sim.sh test      # the same with the packages of build-pi in containers, without the QEMU image
./ecu-sim.sh down
```

For `up` and the tests, the simulator, its ECU databases and the ECU settings come from the CDA commit that `inc_diagnostics` pins. The VM of `run-qemu` is a host on the simulator's network at `172.42.1.100`: nothing of it is published on the host, the gateway listens on that address (port 7690) and the CDA only on a Unix domain socket in the VM. `test` runs the aarch64 binaries in arm64 containers, so it needs `./dev.sh build-pi` first. Both tests require `jq` on the host and obtain a fresh development token from the gateway.

The Pi image is built like the QEMU image: the EB corbos toolkit image for the Raspberry Pi 4B with the platform, the showcases and the diagnostics service deployed in it (`//images/ebclfsa_rpi4b:image` in `reference_integration`), so it starts the stack at boot as well. It is for integration tests, not production: root can log in over ssh without a password.

### ECU simulator with a physical Raspberry Pi

On macOS, Docker Desktop's network is isolated from the Pi's Ethernet; the `up` container cannot be used directly by the Pi. Instead, `pi` builds the simulator in Docker and runs it **on the Mac** with Java 21. It uses a separate simulator source pinned to the merged [CDA PR #766](https://github.com/eclipse-opensovd/classic-diagnostic-adapter/pull/766); the Pi image's CDA and databases still come from the `inc_diagnostics` pin. This combination has not been verified end to end at the current pins.

Connect the Pi and Mac by Ethernet. For the default Pi address `192.168.7.2/24`, give the Mac's Ethernet interface `192.168.7.1/24` and at least four additional unused addresses in that subnet: the simulator assigns its five DoIP entities to the interface's IPv4 addresses. For example, after configuring `192.168.7.1` in macOS Network Settings, with `PI_IF` set to the actual Ethernet interface (find it with `ifconfig`):

```sh
PI_IF=en7  # replace with the Pi-facing interface
for i in 10 11 12 13; do
  sudo ifconfig "$PI_IF" alias "192.168.7.$i" netmask 255.255.255.0
done
SIM_NETWORK_INTERFACE="$PI_IF" SIM_BROADCAST_ADDRESS=192.168.7.255 ./ecu-sim.sh pi
```

Choose unused addresses; do not use the Pi's address. Check the simulator log's `Assigning entity` lines to confirm that all five entities have distinct Pi-subnet addresses. The simulator runs in the foreground; stop it with Ctrl-C. Remove the example aliases afterwards with `sudo ifconfig "$PI_IF" -alias 192.168.7.10` (and similarly for `.11`–`.13`). The native simulator's control API listens on port 8181 on the host network, not just loopback: use a trusted test network.

`SIM_BROADCAST_ADDRESS` directs the simulator's vehicle announcements to the Pi subnet instead of whichever interface the host chooses for limited broadcast. Use the actual subnet's broadcast address if the Pi network differs. Upstream defaults to `255.255.255.255` when unset, but `pi` requires an explicit address. Directed announcements are for testing and deviate from ISO 13400-2:2025 requirement 8.DoIP-125, which requires limited broadcast.

Start the simulator before booting the Pi, or restart the diagnostics stack on the Pi after the simulator starts. From the Mac, use the Raspberry Pi gateway commands above to list components and read the VIN; the simulator addresses must be reachable over Ethernet. If the interface has extra IPv4 addresses, the simulator may assign those instead: check its log and adjust the interface configuration. `./ecu-sim.sh test` and `test-vm` test the Docker setup, not this native Pi mode.

## Network of the Pi image

The Pi image has a static address and no DHCP client or link-local fallback. `reference_integration` generates `/etc/config/network` (netifd format) with these defaults:

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
- To change the address at build time, set `SCORE_PI_ADDRESS` (with prefix length), `SCORE_PI_GATEWAY` (empty for none) and `SCORE_PI_DNS` (comma separated) when you run `dev.sh`, for example `SCORE_PI_ADDRESS=10.0.0.20/24 SCORE_PI_GATEWAY=10.0.0.1 ./dev.sh build-pi`. A change rebuilds the image, not the platform. `SCORE_PI_MDNS` sets the gateway's advertised vehicle identification, or disables mDNS when empty.
- To change it afterwards, edit `/etc/config/network` over ssh on the running Pi, or in the root partition (the second partition) of the `.wic` file before flashing. `qemu-sim-net.sh` does the latter with `debugfs` for the QEMU image (`172.42.1.100/16`).
- The image has `netifd`, BusyBox `udhcpc` and `systemd-networkd`, but no `avahi-autoipd`, and `/lib/netifd` holds no protocol scripts. Whether `option proto dhcp` or a link-local fallback works was not tried.
- The diagnostics service waits for a network address before it starts the stack, so it starts with the static address as well.
- The diagnostics use the address of the image as well, not the `0.0.0.0` of the generic showcase. The Pi images replace two files of the showcase, built from `SCORE_PI_ADDRESS`:
  - `/showcases/data/diagnostics/opensovd-cda.toml`: `tester_address` and `tester_subnet` of the CDA (for example `192.168.7.2`, `255.255.255.0`). The CDA sends its DoIP vehicle identification from that address. With `0.0.0.0` it needs a route to send it and stops with `Failed to send VIR: ... Network is unreachable` without one, for example with a link-local address and no gateway.
  - `/showcases/data/diagnostics/etc/launch_manager_config.bin`: `SOVD_URL` of the gateway (for example `http://192.168.7.2:7690/sovd`), so the gateway listens on the address of the image only.
- If you change the address on the running Pi, change `tester_address` and `tester_subnet` as well. The address of the gateway is in the binary launch manager configuration and needs a new build of the image.

The configuration is documented in `images/network/README.md` of `reference_integration`.

## How it builds

The hermetic toolchains only run on x86_64 Linux, so `dev.sh` builds in the official devcontainer as `linux/amd64` (emulated, so slow on arm64 hosts), extended with the aarch64 glibc headers that the Pi build needs. It requires Docker Desktop with at least 8 GB RAM.

`reference_integration` cannot be checked out completely on a case-insensitive file system (a `BUILD` file and a `build/` directory share a name). `dev.sh` therefore builds from a clone in the Docker volume `score-ref-int` that it keeps in sync with the submodule pin. Bazel's cache is in the volume `score-bazel-cache`.

## Status

- Verified: `build-pi` at the current pins. It has not been tested on a real Raspberry Pi.
- Earlier pins were verified with `build-qemu`, `run-qemu` and `./ecu-sim.sh test-vm`; the current pins and token flow have not yet been verified end to end in the VM.
- The image starts the diagnostics service at boot. Its gateway uses placeholder development authentication, not production authentication.
- QEMU runs without KVM here, so the VM needs several minutes to boot, and a build next to it can run out of memory.

## License

Apache License 2.0, see [LICENSE](LICENSE). The submodules have their own licenses.
