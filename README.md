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
./dev.sh build-pi     # Raspberry Pi packages -> out/score-platform-linux-aarch64.tar, out/score-showcases-linux-aarch64.tar
./dev.sh build-qemu   # QEMU image (EB corbos Linux for Safety Applications, aarch64), ~30 min the first time
./dev.sh run-qemu     # boot it; SSH on 127.0.0.1:2222 as root, password linux
```

The diagnostics end up in `/usr/bin/diagnostics/` (`opensovd-gateway`, `opensovd-cda`).

```sh
./ecu-sim.sh up       # build and start the CDA's ECU simulator (Docker network score-ecu-sim)
./ecu-sim.sh test     # run the CDA from the build-pi output against it, read the VIN of ECU flxc1000 over SOVD
./ecu-sim.sh down
```

The simulator, its ECU databases and the CDA configuration come from the CDA commit that `inc_diagnostics` pins. `test` runs the aarch64 CDA binary natively in an arm64 container, so it needs `./dev.sh build-pi` first.

For the Pi, install the two tars on Raspberry Pi OS Lite (64-bit) as described in `reference_integration/deploy/README.md`.

## How it builds

The hermetic toolchains only run on x86_64 Linux, so `dev.sh` builds in the official devcontainer as `linux/amd64` (emulated and slow on Apple Silicon), extended with the aarch64 glibc headers that the Pi build needs. It requires Docker Desktop with at least 8 GB RAM.

`reference_integration` cannot be checked out completely on a case-insensitive macOS volume (a `BUILD` file and a `build/` directory share a name). `dev.sh` therefore builds from a clone in the Docker volume `score-ref-int` that it keeps in sync with the submodule pin. Bazel's cache is in the volume `score-bazel-cache`.

## Status

- Built and verified: `build-pi`, `build-qemu`, and `run-qemu` boot the VM. The gateway starts inside it and listens on `127.0.0.1:7690`.
- Not done: the adapter is deployed but not started or configured (it needs a DoIP ECU). Nothing starts the gateway at boot.
- QEMU runs without KVM or HVF here, so the VM is slow.

## License

Apache License 2.0, see [LICENSE](LICENSE). The submodules have their own licenses.
