#!/bin/bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# This provides generic functions to use in the Kubernetes e2e tests.
#
set -euo pipefail

# Wait time and sleep time for waiting operations
wait_time=90
sleep_time=3

# Timeout for use with `kubectl wait`
timeout=90s

# Path to the kubeconfig file
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

K8S_TEST_DIR="${BATS_TEST_DIRNAME}"

# Delete all pods if any exist, otherwise just return
k8s_delete_all_pods() {
	[ -z "$(kubectl get pods --all-namespaces --no-headers 2>/dev/null)" ] || \
		kubectl delete pods --all --all-namespaces --force --grace-period=0 2>/dev/null || true
}

# Wait until the pod is Ready. Fail if it hits the timeout.
# Parameters:
#   $1 - the pod name
#   $2 - namespace (optional, defaults to default)
#   $3 - wait time in seconds. Defaults to 120. (optional)
k8s_wait_pod_be_ready() {
	local pod_name="$1"
	local namespace="${2:-default}"
	local wait_time="${3:-120}"

	info "Waiting for pod ${pod_name} to be ready (timeout: ${wait_time}s)"
	kubectl wait --timeout="${wait_time}s" --for=condition=ready "pod/${pod_name}" -n "$namespace"
}

# Create a pod with a given number of retries
# Parameters:
#   $1 - the pod configuration file
#   $2 - namespace (optional, defaults to default)
retry_kubectl_apply() {
	local file_path=$1
	local namespace="${2:-default}"
	local retries=5
	local delay=5
	local attempt=1
	local func_name="${FUNCNAME[0]}"

	while true; do
		output=$(kubectl apply -f "$file_path" -n "$namespace" 2>&1) || true
		echo ""
		echo "$func_name: Attempt $attempt/$retries"
		echo "$output"

		# Check for timeout and retry if needed
		if echo "$output" | grep -iq "timed out\|timeout"; then
			if [ $attempt -ge $retries ]; then
				echo "$func_name: Max ${retries} retries reached. Failed due to timeout."
				return 1
			fi
			echo "$func_name: Timeout encountered, retrying in $delay seconds..."
			sleep $delay
			attempt=$((attempt + 1))
			continue
		fi

		# Check for any other kind of error
		if echo "$output" | grep -iq "error"; then
			echo "$func_name: Error detected in kubectl output."
			echo "$output"
			return 1
		fi

		echo "$func_name: Resource created successfully."
		return 0
	done
}

# Create a pod and wait it be ready, otherwise fail.
# Parameters:
#   $1 - the pod configuration file
#   $2 - wait time in seconds. Defaults to 120. (optional)
#   $3 - namespace (optional, defaults to default)
k8s_create_pod() {
	local config_file="$1"
	local wait_time="${2:-120}"
	local namespace="${3:-default}"
	local pod_name=""

	if [ ! -f "${config_file}" ]; then
		echo "Pod config file '${config_file}' does not exist"
		return 1
	fi

	retry_kubectl_apply "${config_file}" "$namespace"

	# Get the pod name from the yaml file
	pod_name=$(yq eval '.metadata.name' "${config_file}")
	if [ -z "$pod_name" ]; then
		echo "Failed to get pod name from config file"
		return 1
	fi

	info "Pod ${pod_name} created, waiting for it to be ready..."
	if ! k8s_wait_pod_be_ready "${pod_name}" "$namespace" "${wait_time}"; then
		# Debug information
		kubectl get pod "${pod_name}" -n "$namespace"
		kubectl describe pod "${pod_name}" -n "$namespace"
		return 1
	fi

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
spec:
  runtimeClassName: ${runtimeclass}
  containers:
  - name: test-container
    image: ${image}
    command: ["tail", "-f", "/dev/null"]
EOF
	else
		IMAGE="$image" RUNTIMECLASS="$runtimeclass" POD_NAME="$pod_name" envsubst < "$base_config" > "$new_config"
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
	kubectl exec "${pod_name}" -- "$@"
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

# Check if pod is running
# Parameters:
#   $1 - pod name
#   $2 - namespace (optional, defaults to default)
is_pod_running() {
	local pod_name="$1"
	local namespace="${2:-default}"
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
	local namespace="${2:-default}"
	kubectl logs "${pod_name}" -n "$namespace"
}

# Delete a pod
# Parameters:
#   $1 - pod name
#   $2 - namespace (optional, defaults to default)
delete_pod() {
	local pod_name="$1"
	local namespace="${2:-default}"
	kubectl delete pod "${pod_name}" -n "$namespace" --ignore-not-found=true
}

# Common setup for tests
# Exports:
#   $node - first available node
#   $pod_config_dir - path to pod configs
setup_common() {
	# Load image configuration
	local script_dir="${BATS_TEST_DIRNAME}"
	if [ -f "${script_dir}/load_images.sh" ]; then
		source "${script_dir}/load_images.sh"
	fi

	# Get a worker node
	node=$(kubectl get node -o name | grep -v "control-plane" | head -1 | sed 's/node\///')
	[[ -n "${node}" ]] || die "No worker nodes found"

	export node

	# Set pod config directory - use work directory with processed images
	if [ -d "${script_dir}/runtimeclass_workloads_work" ]; then
		export pod_config_dir="${script_dir}/runtimeclass_workloads_work"
	else
		export pod_config_dir="${script_dir}/runtimeclass_workloads"
	fi
	info "k8s configured to use runtimeclass: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}"
	info "Using images: BUSYBOX=${BUSYBOX_IMAGE}, NGINX=${NGINX_IMAGE}"

	# Clean up any existing pods
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
