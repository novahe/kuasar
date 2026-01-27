# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kuasar is a multi-sandbox container runtime built in Rust that provides a unified abstraction layer for different sandbox technologies (MicroVM, WebAssembly, App Kernel, and runC). It implements the containerd Sandbox API, treating sandboxes as first-class citizens.

**Key architectural principle**: Kuasar replaces the traditional shim v2 model (1:1 shim-to-sandbox) with a 1:N model where a single sandboxer process manages multiple sandboxes, eliminating pause containers and reducing resource overhead by 99%.

## Build Commands

### Main Build Targets

```bash
# Build all sandboxers (vmm, quark, wasm, runc)
make all

# Build specific sandboxers
make vmm              # MicroVM sandboxer (vmm-sandboxer + vmm-task + kernel + image)
make wasm             # WebAssembly sandboxer
make quark            # Quark app-kernel sandboxer
make runc             # runC sandboxer

# Build individual components
make bin/vmm-sandboxer   # Build VMM sandboxer (host-side)
make bin/vmm-task        # Build VMM task (VM guest init process)
make bin/vmlinux.bin     # Build guest kernel
make bin/kuasar.img      # Build guest OS image (cloud-hypervisor)
make bin/kuasar.initrd   # Build guest initrd (stratovirt/qemu)
```

### Build Variables

```bash
# Select hypervisor for VMM (default: cloud_hypervisor)
make vmm HYPERVISOR=cloud_hypervisor    # Options: cloud_hypervisor, qemu, stratovirt

# Guest OS image type (default: centos)
make vmm GUESTOS_IMAGE=centos

# WebAssembly runtime (default: wasmedge)
make wasm WASM_RUNTIME=wasmedge    # Options: wasmedge, wasmtime

# Kernel version (default: 6.12.8)
make vmm KERNEL_VERSION=6.12.8

# Architecture (default: x86_64)
make vmm ARCH=x86_64

# Enable Youki integration (default: false)
make runc ENABLE_YOUKI=true
```

### Installation

```bash
# Install all components
make install

# Install specific sandboxers
make install-vmm
make install-wasm
make install-quark
make install-runc

# Install destination (default: /)
make install DEST_DIR=/
```

### Cleaning

```bash
make clean    # Remove build artifacts
```

## Testing

### E2E Testing

```bash
# Run full e2e integration tests
make test-e2e

# Run e2e framework unit tests only (no service startup)
make test-e2e-framework

# Test specific runtime
make test-e2e-runc    # Test runc runtime

# Run tests in parallel
make test-e2e-parallel

# Setup e2e environment
make setup-e2e-env

# Verify e2e environment
make verify-e2e

# Clean test environment
make clean-e2e

# Lint e2e test code
make lint-e2e

# Development workflow (clean + setup + test)
make e2e-dev
```

### E2E Test Variables

```bash
# Runtime to test (default: runc)
make test-e2e RUNTIME=runc

# Artifacts directory
make test-e2e ARTIFACTS_DIR=/path/to/artifacts

# Run tests in parallel
make test-e2e PARALLEL=true

# Log level
make test-e2e LOG_LEVEL=info
```

## Architecture

### Component Structure

Kuasar consists of multiple sandboxer implementations, each following a two-component pattern:

1. **`*-sandboxer`**: Host-side process that implements the Sandbox API for sandbox lifecycle management
2. **`*-task`**: Guest-side or namespace-side process that implements the Task API for container lifecycle management

### Sandboxer Types

#### 1. **VMM Sandboxer** (`vmm/`)

Most complex implementation. Two-process architecture:

- **`vmm-sandboxer`** (host): Manages VM lifecycle using hypervisors (Cloud Hypervisor, QEMU, StratoVirt)
  - Located: `vmm/sandbox/src/`
  - Multiple binary targets: `cloud_hypervisor`, `qemu`, `stratovirt`
  - Hypervisor-specific code in: `vmm/sandbox/src/bin/{hypervisor}/`

- **`vmm-task`** (VM guest PID 1): Init process inside VM, manages containers
  - Located: `vmm/task/src/`
  - Mounts root filesystem, sets up networking
  - Runs ttrpc server on vsock://-1:1024
  - Services: Task API, Sandbox API, Streaming API

**Shared code**: `vmm/common/` - common utilities and types

**Key VMM concepts**:
- VM communication via vsock (host ↔ guest)
- Shared filesystem via virtiofs or 9p
- Guest kernel must have virtio-vsock enabled
- Guest image must have vmm-task as init process and runc installed

#### 2. **Wasm Sandboxer** (`wasm/`)

- **`wasm-sandboxer`**: Manages WebAssembly runtime (WasmEdge/Wasmtime)
- **`wasm-task`**: Forks processes, each running a separate Wasm runtime instance
- Containers in same pod share namespace/cgroup with wasm-task process

#### 3. **Quark Sandboxer** (`quark/`)

- **`quark-sandboxer`**: Manages QVisor hypervisor and QKernel
- **`quark-task`**: Runs inside QVisor, calls QKernel to launch containers
- All containers in same pod run within same process

#### 4. **Runc Sandboxer** (`runc/`)

- **`runc-sandboxer`**: Creates lightweight namespaces via double-fork
- **`runc-task`**: Becomes PID 1 in namespace, manages containers
- Optional Youki integration via `ENABLE_YOUKI=true`

### Support Components

#### **Shim** (`shim/`)

Optional workaround for compatibility with containerd (when Sandbox API is not available). Forwards requests between containerd and Kuasar sandboxers.

#### **Tools** (`tools/`)

- **`kuasar-ctl`**: CLI tool for debugging and managing Kuasar sandboxes via vsock
  - Interactive mode for terminal connections
  - Sandbox management commands

### Communication Flow

```
containerd (CRI) → [Unix socket] → *-sandboxer (Sandbox API)
                                              ↓
                    [vsock/namespace] → *-task (Task API)
                                              ↓
                                          runc/runtime
                                              ↓
                                          container process
```

## Directories Reference

```
kuasar/
├── vmm/                    # MicroVM implementation
│   ├── sandbox/            # Host-side vmm-sandboxer
│   │   ├── src/
│   │   │   ├── bin/        # Hypervisor-specific main files
│   │   │   │   ├── cloud_hypervisor/
│   │   │   │   ├── qemu/
│   │   │   │   └── stratovirt/
│   │   │   ├── cloud_hypervisor/  # Cloud Hypervisor integration
│   │   │   ├── qemu/             # QEMU integration
│   │   │   ├── stratovirt/       # StratoVirt integration
│   │   │   ├── container/        # Container management
│   │   │   ├── network/          # Network setup
│   │   │   └── storage/          # Storage handling
│   │   └── config_*.toml   # Hypervisor-specific configs
│   ├── task/               # VM guest-side vmm-task (PID 1)
│   ├── common/             # Shared VMM code
│   ├── scripts/            # Build scripts for kernel/image
│   │   ├── kernel/         # Kernel build scripts
│   │   └── image/          # Rootfs build scripts
│   └── service/            # systemd service files
├── wasm/                   # WebAssembly sandboxer
│   ├── src/
│   └── service/
├── quark/                  # Quark app-kernel sandboxer
│   ├── src/
│   └── service/
├── runc/                   # Runc sandboxer
│   ├── src/
│   └── service/
├── shim/                   # Optional shim for containerd compatibility
├── tests/
│   └── e2e/                # E2E test framework (Rust-based)
├── tools/
│   └── kuasar-ctl/         # Debug/management CLI tool
├── examples/               # Example container launch scripts
├── docs/                   # Documentation
└── hack/                   # Helper scripts for development/testing
```

## Key Dependencies

- **containerd-sandbox**: Sandbox API traits from [kuasar-io/rust-extensions](https://github.com/kuasar-io/rust-extensions)
- **containerd-shim**: Shim utilities from rust-extensions
- **Hypervisor clients**:
  - Cloud Hypervisor: `api_client` from cloud-hypervisor repo
  - QEMU: `qapi` crate for QMP protocol
- **Async runtime**: `tokio` with full features
- **ttrpc**: Rust ttrpc implementation for containerd communication
- **oci-spec**: OCI runtime/spec compliance

## Development Workflow

### Adding a New Hypervisor to VMM

1. Create binary in `vmm/sandbox/src/bin/{hypervisor}/main.rs`
2. Add hypervisor-specific code in `vmm/sandbox/src/{hypervisor}/`
3. Add config template `vmm/sandbox/config_{hypervisor}.toml`
4. Update Makefile HYPERVISOR variable support
5. Add build target in `vmm/sandbox/Cargo.toml` `[[bin]]` section

### Adding a New Wasm Runtime

1. Add feature flag in `wasm/Cargo.toml`
2. Implement runtime-specific initialization
3. Update Makefile WASM_RUNTIME variable

### Debugging VMM Issues

1. Check vmm-task logs inside VM
2. Use `kuasar-ctl` to connect via vsock for debugging
3. Enable debug console: add `task.debug` to kernel_params
4. Connect with: `ncat --vsock <guest-cid> 1025`

### Running a Specific Test

```bash
# E2E tests are in tests/e2e/src/tests.rs
cd tests/e2e
cargo test --release --test-threads=1 --nocapture test_name
```

## Configuration Files

- **VMM config**: `/var/lib/kuasar/config.toml` (installed from `vmm/sandbox/config_*.toml`)
- **systemd services**: Installed to `/usr/lib/systemd/system/kuasar-*.service`
- **Environment config**: `/etc/sysconfig/kuasar-*`

## Important Notes

- **Virtualization required**: MicroVM sandboxer only works on virtualization-enabled hardware
- **Kernel requirements**: Quark requires Linux kernel >= 5.15
- **Musl target**: vmm-task builds with `x86_64-unknown-linux-musl` for minimal dependencies
- **Proxy support**: Build process respects `http_proxy` and `https_proxy`
- **SSL certificates**: For builds with self-signed certs, place CA cert as `proxy.crt` in project root
