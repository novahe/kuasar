#!/bin/bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# This provides generic functions to use in the Kubernetes e2e tests.
#

# Wait time and sleep time for waiting operations
wait_time=90
sleep_time=3

# Timeout for use with `kubectl wait`
timeout=90s

# Path to the kubeconfig file
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# Test namespace
KUASAR_TEST_NAMESPACE="${KUASAR_TEST_NAMESPACE:-kuasar-k8s-integration-test}"

# Test group for pod isolation (allows parallel tests)
# Each test directory should set this to its directory name
TEST_GROUP="${TEST_GROUP:-}"

K8S_TEST_DIR="${BATS_TEST_DIRNAME}"

# Delete pods by test group label, or all pods if no group specified
k8s_delete_all_pods() {
	if [ -n "${TEST_GROUP}" ]; then
		# Delete only pods with this test group label
		[ -z "$(kubectl get pods -n "${KUASAR_TEST_NAMESPACE}" -l "test-group=${TEST_GROUP}" --no-headers 2>/dev/null)" ] || \
			kubectl delete pods -n "${KUASAR_TEST_NAMESPACE}" -l "test-group=${TEST_GROUP}" --force --grace-period=0 2>/dev/null || true
	else
		# Delete all pods (backward compatible)
		[ -z "$(kubectl get pods -n "${KUASAR_TEST_NAMESPACE}" --no-headers 2>/dev/null)" ] || \
			kubectl delete pods --all -n "${KUASAR_TEST_NAMESPACE}" --force --grace-period=0 2>/dev/null || true
	fi
}

# Wait until the pod is Ready. Fail if it hits the timeout.
# Parameters:
#   $1 - the pod name
#   $2 - namespace (optional, defaults to default)
#   $3 - wait time in seconds. Defaults to 120. (optional)
k8s_wait_pod_be_ready() {
	local pod_name="$1"
	local namespace="${2:-${KUASAR_TEST_NAMESPACE}}"
	local wait_time="${3:-120}"

	kubectl wait --timeout="${wait_time}s" --for=condition=ready "pod/${pod_name}" -n "$namespace" >/dev/null
}

# Create a pod with a given number of retries
# Parameters:
#   $1 - the pod configuration file
#   $2 - namespace (optional, defaults to default)
retry_kubectl_apply() {
	local file_path=$1
	local namespace="${2:-${KUASAR_TEST_NAMESPACE}}"
	local retries=5
	local delay=5
	local attempt=1
	local func_name="${FUNCNAME[0]}"

	# Process template variables if file contains ${}
	if grep -q '\${' "$file_path" 2>/dev/null; then
		# Export required variables for envsubst
		export KUASAR_RUNTIME_CLASS BUSYBOX_IMAGE NGINX_IMAGE TEST_GROUP KUASAR_TEST_NAMESPACE
		# Create temp file with substituted variables
		local temp_file=$(mktemp)
		envsubst < "$file_path" > "$temp_file"
		file_path="$temp_file"
	fi

	while true; do
		output=$(kubectl apply -f "$file_path" -n "$namespace" 2>&1) || true

		# Clean up temp file if it was created
		if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
			rm -f "$temp_file"
		fi
		temp_file=""

		# Check for timeout and retry if needed
		if echo "$output" | grep -iq "timed out\|timeout"; then
			if [ $attempt -ge $retries ]; then
				echo "$func_name: Max ${retries} retries reached. Failed due to timeout." >&2
				return 1
			fi
			echo "$func_name: Timeout encountered, retrying in $delay seconds..." >&2
			sleep $delay
			attempt=$((attempt + 1))
			continue
		fi

		# Check for any other kind of error
		if echo "$output" | grep -iq "error"; then
			echo "$func_name: Error detected in kubectl output." >&2
			echo "$output" >&2
			return 1
		fi

		return 0
	done
}

# Create a pod and wait it be ready, otherwise fail.
# Parameters:
#   $1 - the pod configuration file
#   $2 - wait time in seconds. Defaults to 120. (optional)
#   $3 - namespace (optional, defaults to default)
# Returns:
#   The pod name on stdout (only the name, no other output)
k8s_create_pod() {
	local config_file="$1"
	local wait_time="${2:-120}"
	local namespace="${3:-${KUASAR_TEST_NAMESPACE}}"
	local pod_name=""

	if [ ! -f "${config_file}" ]; then
		echo "Pod config file '${config_file}' does not exist" >&2
		return 1
	fi

	retry_kubectl_apply "${config_file}" "$namespace"

	# Get the pod name from the yaml file
	pod_name=$(yq eval '.metadata.name' "${config_file}")
	if [ -z "$pod_name" ]; then
		echo "Failed to get pod name from config file" >&2
		return 1
	fi

	if ! k8s_wait_pod_be_ready "${pod_name}" "$namespace" "${wait_time}"; then
		# Debug information
		kubectl get pod "${pod_name}" -n "$namespace" >&2 || true
		kubectl describe pod "${pod_name}" -n "$namespace" >&2 || true
		return 1
	fi

	# Only output the pod name to stdout
	echo "${pod_name}"
}

# Create a pod configuration out of a template file.
# Parameters:
#   $1 - the container image
#   $2 - the runtimeclass (optional, defaults to KUASAR_RUNTIME_CLASS)
#   $3 - pod name (optional)
# Return:
#   the path to the configuration file
new_pod_config() {
	local FIXTURES_DIR="${BATS_TEST_DIRNAME}/runtimeclass_workloads"
	local base_config="${FIXTURES_DIR}/pod-template.yaml"
	local image="$1"
	local runtimeclass="${2:-$KUASAR_RUNTIME_CLASS}"
	local pod_name="${3:-test-pod-$$}"
	local new_config

	[ -n "$runtimeclass" ] || return 1

	new_config=$(mktemp "${BATS_FILE_TMPDIR}/pod-config.XXXXXX.yaml")

	# Create a simple pod config if template doesn't exist
	if [ ! -f "$base_config" ]; then
		cat > "$new_config" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  labels:
    test-group: ${TEST_GROUP:-default}
spec:
  runtimeClassName: ${runtimeclass}
  containers:
  - name: test-container
    image: ${image}
    command: ["tail", "-f", "/dev/null"]
EOF
	else
		IMAGE="$image" RUNTIMECLASS="$runtimeclass" POD_NAME="$pod_name" TEST_GROUP="${TEST_GROUP:-default}" envsubst < "$base_config" > "$new_config"
	fi

	echo "$new_config"
}

# Execute a command in a pod
# Parameters:
#   $1 - pod name
#   $2+ - the command to execute
pod_exec() {
	local pod_name="$1"
	shift
	kubectl exec "${pod_name}" -n "${KUASAR_TEST_NAMESPACE}" -- "$@"
}

# Execute a command in a pod and check for expected output
# Parameters:
#   $1 - pod name
#   $2 - expected pattern to grep
#   $3+ - the command to execute
grep_pod_exec() {
	local pod_name="$1"
	local grep_pattern="$2"
	shift 2
	pod_exec "${pod_name}" "$@" | grep "${grep_pattern}"
}

# Execute a command in a pod and check for expected output (verbose)
# Parameters:
#   $1 - pod name
#   $2 - expected pattern to grep
#   $3+ - the command to execute
grep_pod_exec_output() {
	local pod_name="$1"
	local grep_pattern="$2"
	shift 2
	local output
	output=$(pod_exec "${pod_name}" "$@" 2>&1)
	echo "$output"
	echo "$output" | grep "${grep_pattern}"
}

# Check if pod is running
# Parameters:
#   $1 - pod name
#   $2 - namespace (optional, defaults to KUASAR_TEST_NAMESPACE)
is_pod_running() {
	local pod_name="$1"
	local namespace="${2:-${KUASAR_TEST_NAMESPACE}}"
	local phase

	phase=$(kubectl get pod "${pod_name}" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
	[ "$phase" = "Running" ]
}

# Get pod logs
# Parameters:
#   $1 - pod name
#   $2 - namespace (optional, defaults to default)
get_pod_logs() {
	local pod_name="$1"
	local namespace="${2:-${KUASAR_TEST_NAMESPACE}}"
	kubectl logs "${pod_name}" -n "$namespace"
}

# Delete a pod
# Parameters:
#   $1 - pod name
#   $2 - namespace (optional, defaults to default)
delete_pod() {
	local pod_name="$1"
	local namespace="${2:-${KUASAR_TEST_NAMESPACE}}"
	kubectl delete pod "${pod_name}" -n "$namespace" --ignore-not-found=true
}

# Common setup for tests
# Exports:
#   $node - first available node
#   $pod_config_dir - path to pod configs
#   $TEST_GROUP - test group label for pod isolation
setup_common() {
	# Load image configuration
	local script_dir="${BATS_TEST_DIRNAME}"
	# Handle both root and subdirectory test files
	if [ -f "${script_dir}/load_images.sh" ]; then
		source "${script_dir}/load_images.sh"
	elif [ -f "${script_dir}/../load_images.sh" ]; then
		source "${script_dir}/../load_images.sh"
	fi

	# Get a worker node
	node=$(kubectl get node -o name | grep -v "control-plane" | head -1 | sed 's/node\///')
	[[ -n "${node}" ]] || die "No worker nodes found"

	export node

	# Set pod config directory - use work directory with processed images
	# Handle both root and subdirectory test files
	if [ -d "${script_dir}/runtimeclass_workloads_work" ]; then
		export pod_config_dir="${script_dir}/runtimeclass_workloads_work"
	elif [ -d "${script_dir}/../runtimeclass_workloads_work" ]; then
		export pod_config_dir="${script_dir}/../runtimeclass_workloads_work"
	elif [ -d "${script_dir}/runtimeclass_workloads" ]; then
		export pod_config_dir="${script_dir}/runtimeclass_workloads"
	else
		export pod_config_dir="${script_dir}/../runtimeclass_workloads"
	fi

	# Set TEST_GROUP based on directory name for pod isolation
	# Extract the last directory name from BATS_TEST_DIRNAME
	local test_dir_name=$(basename "${script_dir}")
	export TEST_GROUP="${test_dir_name}"

	info "k8s configured to use runtimeclass: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}"
	info "Using images: BUSYBOX=${BUSYBOX_IMAGE}, NGINX=${NGINX_IMAGE}"
	info "Test group: ${TEST_GROUP}"

	# Clean up any existing pods in this test group
	k8s_delete_all_pods || true
}

# Common teardown for tests
# Parameters:
#   $1 - node name (optional)
teardown_common() {
	local node="${1:-}"

	k8s_delete_all_pods || true

	# Print node logs if test failed and node is specified
	if [[ -n "${node}" && -z "${BATS_TEST_COMPLETED:-}" ]]; then
		info "Test failed, here are the pod details:"
		kubectl describe pods --all-namespaces 2>/dev/null || true
	fi
}

# Helper to add test-group labels to pod metadata
# Usage: add_pod_labels <pod_name> [additional_labels]
add_pod_labels() {
	local pod_name="$1"
	local additional_labels="$2"
	local base_labels="  labels:\n    test-group: ${TEST_GROUP:-default}"

	if [ -n "$additional_labels" ]; then
		echo "${base_labels}\n${additional_labels}"
	else
		echo "${base_labels}"
	fi
}

