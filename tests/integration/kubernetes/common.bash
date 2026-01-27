#!/usr/bin/env bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# This file contains common functions that are being used by Kuasar tests

this_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export repo_root_dir="$(cd "${this_script_dir}/../../" && pwd)"

# Kuasar tests directory used for storing various test-related artifacts
KUASAR_TESTS_BASEDIR="${KUASAR_TESTS_BASEDIR:-/var/log/kuasar-tests}"

# Directory that can be used for storing test logs
KUASAR_TESTS_LOGDIR="${KUASAR_TESTS_LOGDIR:-${KUASAR_TESTS_BASEDIR}/logs}"

# Directory that can be used for storing test data
KUASAR_TESTS_DATADIR="${KUASAR_TESTS_DATADIR:-${KUASAR_TESTS_BASEDIR}/data}"

# Runtime class to test
KUASAR_RUNTIME_CLASS="${KUASAR_RUNTIME_CLASS:-kuasar-vmm}"

# Runtime type (vmm, wasm, quark, runc)
KUASAR_RUNTIME_TYPE="${KUASAR_RUNTIME_TYPE:-vmm}"

function die() {
	local msg="$*"
	echo -e "[$(basename $0):${BASH_LINENO[0]}] ERROR: $msg" >&2
	exit 1
}

function warn() {
	local msg="$*"
	echo -e "[$(basename $0):${BASH_LINENO[0]}] WARNING: $msg"
}

function info() {
	local msg="$*"
	echo -e "[$(basename $0):${BASH_LINENO[0]}] INFO: $msg"
}

function bats_unbuffered_info() {
	local msg="$*"
	# Ask bats to print this text immediately rather than buffering
	echo -e "[$(basename $0):${BASH_LINENO[0]}] UNBUFFERED: INFO: $msg" >&3
}

function handle_error() {
	local exit_code="${?}"
	local line_number="${1:-}"
	echo -e "[$(basename $0):$line_number] ERROR: $(eval echo "$BASH_COMMAND")"
	exit "${exit_code}"
}
trap 'handle_error $LINENO' ERR

# Check if kubectl is available and configured
function check_kubectl() {
	if ! command -v kubectl &> /dev/null; then
		die "kubectl is not installed or not in PATH. Please install kubectl first."
	fi

	if ! kubectl cluster-info &> /dev/null; then
		die "kubectl cannot connect to Kubernetes cluster. Please configure kubeconfig or ensure cluster is accessible."
	fi

	info "kubectl is available and cluster is accessible"
}

# Wait for a process to complete
function waitForProcess() {
	wait_time="$1"
	sleep_time="$2"
	cmd="$3"
	while [ "$wait_time" -gt 0 ]; do
		if eval "$cmd"; then
			return 0
		else
			sleep "$sleep_time"
			wait_time=$((wait_time-sleep_time))
		fi
	done
	return 1
}

# Retry a command
function retry_cmd() {
	local max_tries=5
	local interval=5
	local attempt=1

	while [ $attempt -le $max_tries ]; do
		if "$@"; then
			return 0
		fi
		info "Command failed, attempt $attempt/$max_tries, retrying in ${interval}s..."
		sleep $interval
		attempt=$((attempt + 1))
	done

	return 1
}

# Ensure required tools are available
function ensure_tools() {
	local tools=("kubectl" "yq" "bats")
	local missing=()

	for tool in "${tools[@]}"; do
		if ! command -v "$tool" &> /dev/null; then
			missing+=("$tool")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		die "Missing required tools: ${missing[*]}. Please install them first."
	fi
}

# Get the first worker node
function get_one_node() {
	local node_label="${1:-}"
	if [ -n "$node_label" ]; then
		kubectl get node -l "$node_label" -o name | head -1
	else
		kubectl get node -o name | grep -v "control-plane" | head -1
	fi | sed 's/node\///'
}

# Cleanup function for tests
function cleanup_test_resources() {
	info "Cleaning up test resources..."
	kubectl delete pods --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
	kubectl delete deployments --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
	kubectl delete services --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
	kubectl delete configmaps --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
	kubectl delete secrets --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
}
