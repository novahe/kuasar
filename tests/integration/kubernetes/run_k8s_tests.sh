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
K8S_TEST_DEBUG="${K8S_TEST_DEBUG:-false}"
K8S_TEST_FAIL_FAST="${K8S_TEST_FAIL_FAST:-no}"
K8S_TEST_PARALLEL_JOBS="${K8S_TEST_PARALLEL_JOBS:-4}"

# Test unions - aligned with Kata's approach
if [ -n "${K8S_TEST_UNION:-}" ]; then
	K8S_TEST_UNION=($K8S_TEST_UNION)
else
	# Basic tests for Kuasar
	K8S_TEST_UNION=(
		"k8s-pod-lifecycle.bats"
		"k8s-configmap.bats"
		"k8s-env-comprehensive.bats"
		"k8s-exec.bats"
		"k8s-volume.bats"
		"k8s-shared-volume.bats"
		"k8s-empty-dirs.bats"
		"k8s-credentials-secrets.bats"
		"k8s-nginx-connectivity.bats"
		"k8s-service-connectivity.bats"
		"k8s-service-account.bats"
		"k8s-dns-policy.bats"
		"k8s-init-containers.bats"
		"k8s-seccomp.bats"
		"k8s-job.bats"
		"k8s-cron-job.bats"
		"k8s-liveness-probes.bats"
		"k8s-pid-ns.bats"
		"k8s-cpu-ns.bats"
		"k8s-parallel.bats"
	)
fi

# Display configuration
info "======================================="
info "Kuasar Kubernetes E2E Test Runner"
info "======================================="
info "RuntimeClass: ${KUASAR_RUNTIME_CLASS}"
info "RuntimeType: ${KUASAR_RUNTIME_TYPE}"
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
