#!/usr/bin/env bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Run Kuasar Kubernetes e2e tests using bats

set -e

script_dir=$(dirname "$(readlink -f "$0")")
source "${script_dir}/common.bash"

# Cleanup function
cleanup() {
	info "Cleaning up test resources..."
	cleanup_test_resources
}

trap cleanup EXIT

# Configuration
KUASAR_RUNTIME_CLASS="${KUASAR_RUNTIME_CLASS:-kuasar-vmm}"
KUASAR_RUNTIME_TYPE="${KUASAR_RUNTIME_TYPE:-vmm}"
KUASAR_TEST_NAMESPACE="${KUASAR_TEST_NAMESPACE:-kuasar-k8s-integration-test}"
K8S_TEST_DEBUG="${K8S_TEST_DEBUG:-false}"
K8S_TEST_FAIL_FAST="${K8S_TEST_FAIL_FAST:-no}"
K8S_TEST_PARALLEL_JOBS="${K8S_TEST_PARALLEL_JOBS:-7}"

# Test unions - aligned with Kata's approach
if [ -n "${K8S_TEST_UNION:-}" ]; then
	K8S_TEST_UNION=($K8S_TEST_UNION)
else
	# Basic tests for Kuasar
	K8S_TEST_UNION=(
		# Lifecycle tests
		"lifecycle/k8s-pod-lifecycle.bats"
		"lifecycle/k8s-init-containers.bats"
		# Environment tests
		"environment/k8s-env-comprehensive.bats"
		# Networking tests
		"networking/k8s-dns-policy.bats"
		"networking/k8s-service-connectivity.bats"
		"networking/k8s-nginx-connectivity.bats"
		# Storage tests
		"storage/k8s-volume.bats"
		"storage/k8s-shared-volume.bats"
		"storage/k8s-empty-dirs.bats"
		# Security tests
		"security/k8s-seccomp.bats"
		"security/k8s-service-account.bats"
		"security/k8s-credentials-secrets.bats"
		# Resources tests
		"resources/k8s-configmap.bats"
		"resources/k8s-cpu-ns.bats"
		"resources/k8s-pid-ns.bats"
		# Workload tests
		"workloads/k8s-job.bats"
		"workloads/k8s-cron-job.bats"
		"workloads/k8s-deployment.bats"
		# Lifecycle tests (continued)
		"lifecycle/k8s-liveness-probes.bats"
		"lifecycle/k8s-exec.bats"
		"lifecycle/k8s-parallel.bats"
	)
fi

# Display configuration
info "======================================="
info "Kuasar Kubernetes E2E Test Runner"
info "======================================="
info "RuntimeClass: ${KUASAR_RUNTIME_CLASS}"
info "RuntimeType: ${KUASAR_RUNTIME_TYPE}"
info "Test Namespace: ${KUASAR_TEST_NAMESPACE}"
info "Fail Fast: ${K8S_TEST_FAIL_FAST}"
info "Debug: ${K8S_TEST_DEBUG}"
info "Parallel Jobs: ${K8S_TEST_PARALLEL_JOBS}"
info "Test files: ${#K8S_TEST_UNION[@]}"
info "======================================="

# Check prerequisites
check_kubectl
ensure_tools

# Setup tests
info "Running setup..."
"${script_dir}/setup.sh"

# Set bats options
export BATS_TEST_FAIL_FAST="${K8S_TEST_FAIL_FAST}"
export KUASAR_RUNTIME_CLASS
export KUASAR_RUNTIME_TYPE
export KUASAR_TEST_NAMESPACE

# Run tests
info "Starting tests..."
cd "${script_dir}"

if [ "${K8S_TEST_DEBUG}" = "true" ]; then
	bats --verbose --trace "${K8S_TEST_UNION[@]}"
else
	# Run tests in parallel if supported
	if bats --help | grep -q "jobs"; then
		info "Running tests in parallel with ${K8S_TEST_PARALLEL_JOBS} jobs..."
		bats --jobs "${K8S_TEST_PARALLEL_JOBS}" "${K8S_TEST_UNION[@]}"
	else
		info "Running tests sequentially..."
		bats "${K8S_TEST_UNION[@]}"
	fi
fi

info "All tests completed!"
