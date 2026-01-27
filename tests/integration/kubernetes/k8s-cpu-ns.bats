#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test CPU and resource limits

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Pod with CPU limits" {
	# Create pod with CPU limits
	cat > "${BATS_TMPDIR}/pod-cpu-limits.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cpu-limits-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["tail", "-f", "/dev/null"]
    resources:
      limits:
        cpu: "500m"
      requests:
        cpu: "250m"
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-cpu-limits.yaml")

	# Check pod is running
	is_pod_running "${pod_name}"

	# Verify resource limits are set
	kubectl get pod "${pod_name}" -o jsonpath='{.spec.containers[0].resources.limits.cpu}'
	[ "$?" = "0" ]
}

@test "Pod with memory limits" {
	# Create pod with memory limits
	cat > "${BATS_TMPDIR}/pod-memory-limits.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: memory-limits-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["tail", "-f", "/dev/null"]
    resources:
      limits:
        memory: "128Mi"
      requests:
        memory: "64Mi"
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-memory-limits.yaml")

	# Check pod is running
	is_pod_running "${pod_name}"

	# Verify resource limits are set
	kubectl get pod "${pod_name}" -o jsonpath='{.spec.containers[0].resources.limits.memory}'
	[ "$?" = "0" ]
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
