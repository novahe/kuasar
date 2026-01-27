#!/usr/bin/env bash
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Setup script for Kuasar Kubernetes e2e tests

set -o errexit
set -o nounset
set -o pipefail

DEBUG="${DEBUG:-}"
[ -n "$DEBUG" ] && set -x

export KUASAR_RUNTIME_CLASS="${KUASAR_RUNTIME_CLASS:-kuasar-vmm}"
export KUASAR_RUNTIME_TYPE="${KUASAR_RUNTIME_TYPE:-vmm}"

declare -r script_dir=$(dirname "$(readlink -f "$0")")
source "${script_dir}/common.bash"
source "${script_dir}/load_images.sh"

declare -r runtimeclass_workloads_work_dir="${script_dir}/runtimeclass_workloads_work"
declare -r runtimeclass_workloads_dir="${script_dir}/runtimeclass_workloads"

# Info message
info() {
	echo "[INFO] $*"
}

# Error message
error() {
	echo "[ERROR] $*" >&2
	exit 1
}

# Check if kubectl is available
check_kubectl_available() {
	if ! command -v kubectl &> /dev/null; then
		error "kubectl is not installed or not in PATH. Please install kubectl first."
	fi

	if ! kubectl cluster-info &> /dev/null; then
		error "kubectl cannot connect to Kubernetes cluster. Please configure kubeconfig or ensure cluster is accessible."
	fi

	info "kubectl is available and cluster is accessible"
}

# Check if yq is available
check_yq_available() {
	if ! command -v yq &> /dev/null; then
		error "yq is not installed. Please install yq first."
	fi

	info "yq is available"
}

# Check if bats is available
check_bats_available() {
	if ! command -v bats &> /dev/null; then
		error "bats is not installed. Please install bats-core first."
	fi

	info "bats is available"
}

# Check if Kuasar RuntimeClass exists
check_runtimeclass() {
	info "Checking if RuntimeClass '${KUASAR_RUNTIME_CLASS}' exists..."

	if kubectl get runtimeclass "${KUASAR_RUNTIME_CLASS}" &> /dev/null; then
		info "RuntimeClass '${KUASAR_RUNTIME_CLASS}' found"
		kubectl get runtimeclass "${KUASAR_RUNTIME_CLASS}" -o yaml
		return 0
	else
		warn "RuntimeClass '${KUASAR_RUNTIME_CLASS}' not found"
		info "Available RuntimeClasses:"
		kubectl get runtimeclass 2>/dev/null || echo "  None"
		return 1
	fi
}

# Create RuntimeClass if it doesn't exist
create_runtimeclass() {
	local handler="${KUASAR_RUNTIME_TYPE}-sandboxer"

	info "Creating RuntimeClass '${KUASAR_RUNTIME_CLASS}' with handler '${handler}'..."

	cat > /tmp/kuasar-runtimeclass.yaml <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: ${KUASAR_RUNTIME_CLASS}
handler: ${handler}
EOF

	kubectl apply -f /tmp/kuasar-runtimeclass.yaml
	rm -f /tmp/kuasar-runtimeclass.yaml

	info "RuntimeClass created successfully"
}

# Reset workloads work directory
reset_workloads_work_dir() {
	rm -rf "${runtimeclass_workloads_work_dir}"
	cp -R "${runtimeclass_workloads_dir}" "${runtimeclass_workloads_work_dir}"

	# Replace image placeholders with actual images
	info "Replacing image placeholders..."
	find "${runtimeclass_workloads_work_dir}" -name "*.yaml" -type f -exec \
		${script_dir}/process_yaml_templates.sh {} \;

	info "Workloads work directory reset with images: BUSYBOX=${BUSYBOX_IMAGE}, NGINX=${NGINX_IMAGE}"
}

# Main setup function
main() {
	info "Starting Kuasar Kubernetes e2e test setup..."
	info "RuntimeClass: ${KUASAR_RUNTIME_CLASS}"
	info "RuntimeType: ${KUASAR_RUNTIME_TYPE}"

	# Check prerequisites
	check_kubectl_available
	check_yq_available
	check_bats_available

	# Check or create RuntimeClass
	if ! check_runtimeclass; then
		if [ "${AUTO_CREATE_RUNTIMECLASS:-yes}" = "yes" ]; then
			create_runtimeclass
		else
			error "RuntimeClass '${KUASAR_RUNTIME_CLASS}' not found and AUTO_CREATE_RUNTIMECLASS is not 'yes'. Exiting."
		fi
	fi

	# Prepare workloads
	reset_workloads_work_dir

	info "Setup completed successfully!"
	info "You can now run tests with: ./run_k8s_tests.sh"
}

main "$@"
