#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Kubernetes secrets

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Secret for a pod" {
	# Create Secret
	cat > "${BATS_TMPDIR}/test-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
type: Opaque
stringData:
  username: admin
  password: secret123
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-secret.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Verify Secret creation
	kubectl get secret test-secret -n "${KUASAR_TEST_NAMESPACE}" -o yaml | grep -q "username"

	# Create pod that uses Secret
	cat > "${BATS_TMPDIR}/pod-secret.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secret-test-pod
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo username=\$USERNAME && echo password=\$PASSWORD && tail -f /dev/null"]
    env:
    - name: USERNAME
      valueFrom:
        secretKeyRef:
          name: test-secret
          key: username
    - name: PASSWORD
      valueFrom:
        secretKeyRef:
          name: test-secret
          key: password
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-secret.yaml")

	# Check env vars from secret
	grep_pod_exec_output "${pod_name}" "username=admin" sh -c "echo username=\$USERNAME"
	grep_pod_exec_output "${pod_name}" "password=secret123" sh -c "echo password=\$PASSWORD"

	# Cleanup
	kubectl delete secret test-secret -n "${KUASAR_TEST_NAMESPACE}"
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete secrets --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
