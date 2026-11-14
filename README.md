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
```

The diagnostics end up in `/usr/bin/diagnostics/` (`opensovd-gateway`, `opensovd-cda`). The showcase `Diagnostics Stack` (`/showcases/data/diagnostics`) starts them with the launch manager.

```sh
./ecu-sim.sh up        # build and start the CDA's ECU simulator (Docker network score-ecu-sim)
./ecu-sim.sh test-vm   # with run-qemu running: start the stack in the VM, read the VIN of ECU flxc1000 through its gateway
./ecu-sim.sh test      # the same with the packages of build-pi in containers, without the QEMU image
./ecu-sim.sh down
```

The simulator, its ECU databases and the ECU settings come from the CDA commit that `inc_diagnostics` pins. The VM of `run-qemu` is a host on the simulator's network at `172.42.1.100`: nothing of it is published on the host, the gateway listens on that address (port 7690) and the CDA only on the loopback address of the VM. `test` runs the aarch64 binaries natively in arm64 containers, so it needs `./dev.sh build-pi` first. The gateway has no `/authorize` yet, so the tests send a fixed development token.

The Pi image is built like the QEMU image: the EB corbos toolkit image for the Raspberry Pi 4B with the platform, the showcases and the diagnostics service deployed in it (`//images/ebclfsa_rpi4b:image` in `reference_integration`), so it starts the stack at boot as well. It is for integration tests, not production: root can log in over ssh without a password.

## How it builds

The hermetic toolchains only run on x86_64 Linux, so `dev.sh` builds in the official devcontainer as `linux/amd64` (emulated, so slow on arm64 hosts), extended with the aarch64 glibc headers that the Pi build needs. It requires Docker Desktop with at least 8 GB RAM.

`reference_integration` cannot be checked out completely on a case-insensitive file system (a `BUILD` file and a `build/` directory share a name). `dev.sh` therefore builds from a clone in the Docker volume `score-ref-int` that it keeps in sync with the submodule pin. Bazel's cache is in the volume `score-bazel-cache`.

## Status

- Verified: `build-pi`, `build-qemu`, `run-qemu` and `./ecu-sim.sh test-vm`: the gateway and the CDA in the VM read the VIN of a simulated ECU, and the CDA is not reachable directly.
- Not done: nothing starts the stack when the VM boots (the showcase does, `test-vm` starts it over ssh), and the gateway has no authentication.
- QEMU runs without KVM here, so the VM needs several minutes to boot, and a build next to it can run out of memory.

## License

Apache License 2.0, see [LICENSE](LICENSE). The submodules have their own licenses.
