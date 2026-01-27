#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test liveness probes

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Liveness probe" {
	# Create pod with liveness probe
	cat > "${BATS_TMPDIR}/pod-liveness.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: liveness-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo alive > /tmp/health && sleep 600"]
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/health
      initialDelaySeconds: 5
      periodSeconds: 5
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-liveness.yaml")

	# Check pod is running
	is_pod_running "${pod_name}"

	# Wait for liveness probe to run
	sleep 10

	# Pod should still be running
	is_pod_running "${pod_name}"
}

@test "Readiness probe" {
	# Create pod with readiness probe
	cat > "${BATS_TMPDIR}/pod-readiness.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: readiness-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 5 && echo ready > /tmp/health && sleep 600"]
    readinessProbe:
      exec:
        command:
        - cat
        - /tmp/health
      initialDelaySeconds: 2
      periodSeconds: 2
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-readiness.yaml")

	# Check pod is ready
	kubectl wait --for=condition=ready --timeout=30s "pod/${pod_name}"
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
