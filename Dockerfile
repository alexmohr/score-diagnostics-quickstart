ARG BASE=ghcr.io/eclipse-score/devcontainer:v1.12.0
FROM --platform=linux/amd64 ${BASE}
# QEMU user-mode emulation to run aarch64 cross-builds without a Raspberry Pi.
# (The base image already ships qemu-system-aarch64 / qemu-system-x86_64.)
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends qemu-user file \
 && rm -rf /var/lib/apt/lists/*
