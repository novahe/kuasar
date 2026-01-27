# Kuasar Kubernetes E2E Tests

This directory contains end-to-end tests for Kuasar running on Kubernetes, aligned with Kata Containers' test framework.

## Prerequisites

### Required Tools

- **kubectl** - Kubernetes command-line tool
- **bats** - Bash Automated Testing System (bats-core)
- **yq** - YAML processor

### Installation

```bash
# Install bats-core
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local

# Install yq
sudo snap install yq

# or with go
go install github.com/mikefarah/yq/v4@yq
```

### Kubernetes Cluster

You need access to a running Kubernetes cluster with:

1. Kuasar runtime installed on worker nodes
2. RuntimeClass configured (default: `kuasar-vmm`)
3. Container images available (or configured for offline/air-gapped environments)

## Image Configuration

### Online Environment (Default)

By default, tests use public container images from `quay.io` and Docker Hub. These are configured in `images.conf`:

```bash
BUSYBOX_IMAGE=quay.io/prometheus/busybox:latest
NGINX_IMAGE=nginx:alpine
AGHOST_IMAGE=registry.k8s.io/e2e-test-images/agnhost:2.21
```

### Offline / Air-Gapped Environment

For offline environments, modify `images.conf` to use your local registry:

```bash
# Edit images.conf
vi tests/integration/kubernetes/images.conf

# Change to your local registry
BUSYBOX_IMAGE=your-registry.local/library/busybox:latest
NGINX_IMAGE=your-registry.local/library/nginx:alpine
AGHOST_IMAGE=your-registry.local/library/agnhost:2.21

# Or use the REGISTRY variable
REGISTRY=your-registry.local
```

### Image Configuration File

The `images.conf` file contains all image references used in tests:

| Variable | Default Image | Usage |
|----------|---------------|-------|
| `BUSYBOX_IMAGE` | `quay.io/prometheus/busybox:latest` | Basic pod tests |
| `NGINX_IMAGE` | `nginx:alpine` | Networking tests |
| `AGHOST_IMAGE` | `registry.k8s.io/e2e-test-images/agnhost:2.21` | Advanced K8s tests |

### How It Works

1. `setup.sh` loads image configuration from `images.conf`
2. YAML templates use variables like `${BUSYBOX_IMAGE}` and `${NGINX_IMAGE}`
3. During setup, `process_yaml_templates.sh` replaces variables with actual image values
4. Tests use the processed YAML files from `runtimeclass_workloads_work/`

### Pre-loading Images

For air-gapped environments, preload images on all nodes:

```bash
# Pull and retag for local registry
docker pull quay.io/prometheus/busybox:latest
docker tag quay.io/prometheus/busybox:latest your-registry.local/library/busybox:latest
docker push your-registry.local/library/busybox:latest

# Or directly load on nodes
docker save quay.io/prometheus/busybox:latest | ssh node1 docker load
```

## Directory Structure

```
tests/integration/kubernetes/
├── README.md                    # This file
├── setup.sh                     # Setup script for test environment
├── run_k8s_tests.sh            # Main test runner
├── common.bash                  # Common functions and utilities
├── lib.sh                       # Kubernetes-specific helper functions
├── images.conf                  # Centralized image configuration
├── load_images.sh              # Image configuration loader
├── process_yaml_templates.sh   # Template processor for YAML files
├── k8s-*.bats                   # Individual test files
└── runtimeclass_workloads/      # Pod and workload YAML templates
    ├── pod-template.yaml
    ├── busybox-pod.yaml
    └── nginx-pod.yaml
```

## Usage

### Quick Start

```bash
# 1. Verify your environment
make verify-k8s

# 2. Setup test environment
make setup-k8s

# 3. Run all tests
make test-k8s
```

### Custom Configuration

```bash
# Use custom RuntimeClass
make test-k8s K8S_RUNTIME_CLASS=my-runtime

# Use specific runtime type
make test-k8s K8S_RUNTIME_TYPE=vmm

# Adjust parallel execution (default: 4)
make test-k8s K8S_TEST_PARALLEL_JOBS=8     # 8 parallel jobs
make test-k8s K8S_TEST_PARALLEL_JOBS=1     # Sequential execution

# Run specific test
make test-k8s-single TEST=k8s-pod-lifecycle.bats

# Debug mode (verbose output)
make test-k8s K8S_TEST_DEBUG=true

# Fail fast on first error
make test-k8s K8S_TEST_FAIL_FAST=yes
```

### Manual Test Execution

```bash
cd tests/integration/kubernetes

# Setup
export KUASAR_RUNTIME_CLASS=kuasar-vmm
export KUASAR_RUNTIME_TYPE=vmm
./setup.sh

# Run all tests
./run_k8s_tests.sh

# Run specific test
bats k8s-pod-lifecycle.bats
```

## Test Files

| Test File | Description | Test Cases |
|-----------|-------------|------------|
| `k8s-pod-lifecycle.bats` | **Pod lifecycle including postStart/preStop hooks** | 9 |
| `k8s-configmap.bats` | ConfigMap mounting and usage | 1 |
| `k8s-env-comprehensive.bats` | **All env types: value, ConfigMap, Secret, Downward API, resources** | 8 |
| `k8s-exec.bats` | kubectl exec functionality | 2 |
| `k8s-volume.bats` | Volume mounting (emptyDir) | 1 |
| `k8s-shared-volume.bats` | Shared volumes between containers | 1 |
| `k8s-empty-dirs.bats` | Multiple emptyDir volumes | 1 |
| `k8s-credentials-secrets.bats` | Secret mounting and usage | 1 |
| `k8s-nginx-connectivity.bats` | Network connectivity tests | 1 |
| `k8s-service-connectivity.bats` | **Pod-to-pod communication via Kubernetes Service** | 5 |
| `k8s-seccomp.bats` | **Seccomp security profiles and privileged mode** | 7 |
| `k8s-job.bats` | Kubernetes Job functionality | 1 |
| `k8s-cron-job.bats` | Kubernetes CronJob functionality | 1 |
| `k8s-liveness-probes.bats` | Liveness and readiness probes | 2 |
| `k8s-pid-ns.bats` | PID namespace isolation | 1 |
| `k8s-cpu-ns.bats` | CPU and resource limits | 2 |
| `k8s-parallel.bats` | Multiple pods running in parallel | 1 |
| **Total** | **17 test files** | **45 test cases** |

### Pod Lifecycle Test Details

The `k8s-pod-lifecycle.bats` test file covers comprehensive pod lifecycle management:

| Test Case | Description |
|-----------|-------------|
| `basic lifecycle` | Pod creation, status checking, deletion |
| `custom command` | Pod with custom command/args |
| `postStart hook (exec)` | Exec command after container starts |
| `preStop hook (exec)` | Exec command before container termination |
| `both hooks` | Pod with both postStart and preStop |
| `postStart (HTTP)` | HTTP GET request as postStart hook |
| `graceful termination` | Pod termination with grace period |
| `restart policy: Never` | Container does not restart on failure |
| `restart policy: OnFailure` | Container restarts only on failure |

**Key Features Tested**:
- ✅ Lifecycle hooks (postStart/preStop) with exec commands
- ✅ Lifecycle hooks with HTTP GET requests
- ✅ Graceful termination with `terminationGracePeriodSeconds`
- ✅ Restart policies: Never, OnFailure, Always (default)
- ✅ Pod UID and phase verification

### Environment Variables Test Details

The `k8s-env-comprehensive.bats` test file covers all Kubernetes environment variable types:

| Test Case | Env Type | Description |
|-----------|----------|-------------|
| `direct value` | `value` | Simple fixed parameters |
| `configMapKeyRef` | ConfigMap | Business configuration from ConfigMap |
| `secretKeyRef` | Secret | Passwords, certificates, sensitive data |
| `fieldRef` | Downward API | Pod metadata (IP, Node, name, namespace, labels) |
| `resourceFieldRef` | Resource | CPU/memory limits and requests |
| `mixed types` | Combined | All types in one pod |
| `envFrom ConfigMap` | ConfigMap | Import entire ConfigMap as env vars |
| `envFrom Secret` | Secret | Import entire Secret as env vars |

### Seccomp Security Test Details

The `k8s-seccomp.bats` test file covers security container seccomp profiles:

| Test Case | Description |
|-----------|-------------|
| `default seccomp profile` | Pod with RuntimeDefault seccomp profile |
| `localhost seccomp profile` | Custom seccomp profile that blocks chmod |
| `privileged pod handling` | Security containers don't support privileged mode |
| `dropped capabilities` | NET_RAW and SYS_ADMIN capabilities dropped |
| `added capabilities` | NET_ADMIN capability added |
| `readOnlyRootFilesystem` | Read-only root filesystem with /tmp mount |
| `unconfined seccomp` | All syscalls allowed (unconfined profile) |

**Note**: Security containers (Kuasar VMM) handle privileged mode differently - they maintain isolation even when `privileged: true` is requested.

### Service Connectivity Test Details

The `k8s-service-connectivity.bats` test file covers pod-to-pod communication via Kubernetes Services:

| Test Case | Description |
|-----------|-------------|
| `ClusterIP service` | Access nginx pod via ClusterIP and service name |
| `multiple clients` | Multiple client pods accessing same backend service |
| `multiple endpoints` | Service load balancing across multiple backend pods |
| `headless service` | Direct pod access without ClusterIP (DNS-based) |
| `service env vars` | Automatic service environment variable injection |

**Prerequisites**: Tests wait for CoreDNS to be ready before executing:
```bash
# Tests verify CoreDNS is running (2+ pods ready)
kubectl get pod -n kube-system -l k8s-app=kube-dns
```

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KUASAR_RUNTIME_CLASS` | `kuasar-vmm` | Kubernetes RuntimeClass name |
| `KUASAR_RUNTIME_TYPE` | `vmm` | Kuasar runtime type (runc, vmm, wasm, quark) |
| `K8S_TEST_DEBUG` | `false` | Enable debug output |
| `K8S_TEST_FAIL_FAST` | `no` | Stop on first test failure |
| `K8S_TEST_PARALLEL_JOBS` | `4` | Number of parallel test jobs (1=sequential) |
| `K8S_TEST_UNION` | (all tests) | Specific test files to run |

## RuntimeClass Setup

The tests expect a RuntimeClass to be configured. The setup script will create one if it doesn't exist:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kuasar-vmm
handler: vmm-sandboxer
```

## Adding New Tests

1. Create a new `.bats` file in `tests/integration/kubernetes/`
2. Load the required libraries:
   ```bash
   load "${BATS_TEST_DIRNAME}/lib.sh"
   load "${BATS_TEST_DIRNAME}/common.bash"
   ```
3. Implement test functions:
   ```bash
   setup() {
       setup_common || die "setup_common failed"
   }

   @test "Test description" {
       # Your test code here
   }

   teardown() {
       k8s_delete_all_pods || true
       teardown_common "${node}"
   }
   ```
4. Add the test file to `run_k8s_tests.sh`'s `K8S_TEST_UNION` array if needed

## Test Parallelization

### Default Parallel Execution

Tests run in parallel automatically by default (4 parallel jobs):

```bash
make test-k8s  # Automatically runs in parallel
```

### Customizing Parallel Degree

Control the number of parallel test jobs:

```bash
# Method 1: Via environment variable
export K8S_TEST_PARALLEL_JOBS=8
make test-k8s

# Method 2: Direct script execution
cd tests/integration/kubernetes
K8S_TEST_PARALLEL_JOBS=8 ./run_k8s_tests.sh

# Method 3: Using bats directly
bats --jobs 8 k8s-*.bats
```

### Sequential Execution

Run tests one at a time (useful for debugging):

```bash
# Disable parallel execution
export K8S_TEST_PARALLEL_JOBS=1
make test-k8s

# Or run directly with bats
bats k8s-*.bats
```

### Running Specific Tests in Parallel

Run a subset of tests in parallel:

```bash
# Run specific test files in parallel
bats --jobs 4 k8s-pod-lifecycle.bats k8s-configmap.bats k8s-exec.bats

# Via make
make test-k8s K8S_TEST_UNION="k8s-pod-lifecycle.bats k8s-configmap.bats"
```

### Parallel Execution Best Practices

1. **Cluster Capacity**: Ensure your K8s cluster has enough resources
   - More parallel jobs = more pods running simultaneously
   - Default 4 parallel jobs is safe for most clusters

2. **Resource Limits**: Adjust based on cluster size
   - Small clusters: 2-4 parallel jobs
   - Medium clusters: 4-8 parallel jobs
   - Large clusters: 8-16 parallel jobs

3. **Test Isolation**: Each test creates unique pod names
   - Tests are designed to run independently
   - No shared state between tests

4. **Debugging**: Use sequential mode when investigating failures
   ```bash
   # Sequential mode for debugging
   make test-k8s K8S_TEST_PARALLEL_JOBS=1 K8S_TEST_DEBUG=true
   ```

### Current Parallel Settings

- **Default**: 4 parallel jobs
- **Configuration**: Set `K8S_TEST_PARALLEL_JOBS` environment variable
- **Bats Requirement**: bats-core ≥ 1.0.0 for parallel support

### Check Parallel Support

```bash
# Verify bats supports parallel jobs
bats --help | grep jobs

# Should show:
#   --jobs <N>            Number of parallel jobs (default: number of CPUs)
```

## Troubleshooting

### kubectl cannot connect to cluster

```bash
# Check kubeconfig
echo $KUBECONFIG
kubectl cluster-info

# If needed, set kubeconfig
export KUBECONFIG=/path/to/kubeconfig
```

### RuntimeClass not found

```bash
# Check available RuntimeClasses
kubectl get runtimeclass

# Create manually if needed
kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kuasar-vmm
handler: vmm-sandboxer
EOF
```

### Test pods stuck in pending state

```bash
# Check pod events
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>

# Clean up stuck pods
make clean-k8s
```

## Alignment with Kata Containers

This test framework is aligned with [Kata Containers' Kubernetes e2e tests](https://github.com/kata-containers/kata-containers/tree/main/tests/integration/kubernetes):

- Similar directory structure
- Same bats testing framework
- Compatible helper functions
- Parallel test execution support
- Common test patterns and utilities

## Makefile Targets

```bash
make setup-k8s        # Setup test environment
make test-k8s          # Run all k8s e2e tests
make test-k8s-single   # Run specific test (TEST=file.bats)
make verify-k8s        # Verify test prerequisites
make clean-k8s         # Clean test resources
make help              # Show all available targets
```

## Contributing

When adding new tests:

1. Follow the existing naming convention (`k8s-<feature>.bats`)
2. Include proper setup/teardown
3. Add error handling and cleanup
4. Document the test purpose in this README
5. Ensure tests can run independently

## Pod Feature Coverage

For detailed coverage of all Kubernetes Pod features and what's tested, see **[POD_TEST_COVERAGE.md](./POD_TEST_COVERAGE.md)**.

Quick summary of coverage:
- ✅ **30+ Pod features** fully tested
- ⚠️ **15+ features** recommended to add (Init Containers, DNS Policy, Deployment, etc.)
- **45 test cases** across 17 test files

High priority additions:
- 🔴 Init Containers
- 🔴 DNS Policy
- 🔴 Service Account
- 🟡 Deployment & Rollout

## References

- [Kata Containers E2E Tests](https://github.com/kata-containers/kata-containers/tree/main/tests/integration/kubernetes)
- [bats-core Documentation](https://bats-core.readthedocs.io/)
- [Kubernetes RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
