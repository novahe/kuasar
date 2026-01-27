#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test ConfigMap functionality

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "ConfigMap for a pod" {
	# Create ConfigMap
	cat > "${BATS_TMPDIR}/test-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-configmap
data:
  KUBE_CONFIG_1: "value-1"
  KUBE_CONFIG_2: "value-2"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-configmap.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Verify ConfigMap creation
	kubectl get configmaps test-configmap -n "${KUASAR_TEST_NAMESPACE}" -o yaml | grep -q "KUBE_CONFIG_1"

	# Create pod that uses ConfigMap
	cat > "${BATS_TMPDIR}/pod-configmap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: config-env-test-pod
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "env && tail -f /dev/null"]
    env:
    - name: KUBE_CONFIG_1
      valueFrom:
        configMapKeyRef:
          name: test-configmap
          key: KUBE_CONFIG_1
    - name: KUBE_CONFIG_2
      valueFrom:
        configMapKeyRef:
          name: test-configmap
          key: KUBE_CONFIG_2
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-configmap.yaml")

	# Check env vars
	grep_pod_exec_output "${pod_name}" "KUBE_CONFIG_1=value-1" env
	grep_pod_exec_output "${pod_name}" "KUBE_CONFIG_2=value-2" env

	# Cleanup
	kubectl delete configmap test-configmap -n "${KUASAR_TEST_NAMESPACE}"
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete configmaps --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
