#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test running multiple pods in parallel

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Multiple pods in parallel" {
	# Create multiple pods
	local pod_count=5
	local pod_names=()

	for i in $(seq 1 $pod_count); do
		cat > "${BATS_TMPDIR}/parallel-pod-${i}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: parallel-pod-${i}
  labels:
    app: parallel-test
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo Pod ${i} && tail -f /dev/null"]
EOF

		pod_names+=("parallel-pod-${i}")
		kubectl apply -f "${BATS_TMPDIR}/parallel-pod-${i}.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	done

	# Wait for all pods to be ready
	for pod_name in "${pod_names[@]}"; do
		k8s_wait_pod_be_ready "${pod_name}" "${KUASAR_TEST_NAMESPACE}" "120"
	done

	# Verify all pods are running
	running_count=$(kubectl get pods -l app=parallel-test -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)
	[ "$running_count" -ge "$pod_count" ]

	# Test exec on all pods
	for pod_name in "${pod_names[@]}"; do
		pod_exec "${pod_name}" sh -c "echo 'Test from ${pod_name}'"
	done
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
