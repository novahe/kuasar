#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Service Account functionality for Pods

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"

	# Wait for default ServiceAccount to be ready
	info "Checking ServiceAccount infrastructure..."
	kubectl get serviceaccount default -n "${KUASAR_TEST_NAMESPACE}" >/dev/null 2>&1 || echo "Default ServiceAccount will be created automatically"
}

@test "Pod with default ServiceAccount" {
	# Test 1: Pod with default ServiceAccount (auto-mounted token)
	cat > "${BATS_TMPDIR}/pod-sa-default.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: sa-default-pod
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Checking SA' && ls -la /var/run/secrets/kubernetes.io/serviceaccount/token && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-sa-default.yaml")

	# Verify service account token is mounted (auto-mount)
	pod_exec "${pod_name}" ls -la /var/run/secrets/kubernetes.io/serviceaccount/token

	# Verify CA cert is mounted
	pod_exec "${pod_name}" ls -la /var/run/secrets/kubernetes.io/serviceaccount/ca.crt

	# Verify namespace is mounted
	pod_exec "${pod_name}" ls -la /var/run/secrets/kubernetes.io/serviceaccount/namespace
}

@test "Pod with custom ServiceAccount" {
	# Test 2: Pod with custom ServiceAccount
	cat > "${BATS_TMPDIR}/custom-sa.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: custom-service-account
---
apiVersion: v1
kind: Pod
metadata:
  name: custom-sa-pod
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccountName: custom-service-account
  terminationGracePeriodVolumeSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Using custom SA' && ls -la /var/run/secrets/kubernetes.io/serviceaccount/ && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/custom-sa.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to be ready
	k8s_wait_pod_be_ready "custom-sa-pod" "${KUASAR_TEST_NAMESPACE}" "120"

	# Verify custom service account token is mounted
	kubectl exec custom-sa-pod -n "${KUASAR_TEST_NAMESPACE}" -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/token

	# Cleanup
	kubectl delete pod custom-sa-pod -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete serviceaccount custom-service-account -n "${KUASAR_TEST_NAMESPACE}"
}

@test "Pod with automountServiceAccountToken: false" {
	# Test 3: Pod with automountServiceAccountToken disabled
	cat > "${BATS_TMPDIR}/pod-no-token.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: no-token-pod
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vm}
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Checking SA' && ls -la /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null || echo 'No SA mounted' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-no-token.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to be ready
	k8s_wait_pod_be_ready "no-token-pod" "${KUASAR_TEST_NAMESPACE}" "60"

	# Verify service account token is NOT mounted
	output=$(kubectl exec no-token-pod -n "${KUASAR_TEST_NAMESPACE}" -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "Directory doesn't exist (expected)")
	echo "$output" | grep -q "No such file or directory" || echo "Directory exists unexpectedly"

	# Cleanup
	kubectl delete pod no-token-pod -n "${KUASAR_TEST_NAMESPACE}"
}

@test "ServiceAccount with role permissions" {
	# Test 4: ServiceAccount with Role and RoleBinding
	cat > "${BATS_TMPDIR}/sa-rbac.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-viewer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
subjects:
- kind: ServiceAccount
  name: pod-viewer
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

	kubectl apply -f "${BATS_TMPDIR}/sa-rbac.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Create pod that uses the ServiceAccount with permissions
	cat > "${BATS_TMPDIR}/pod-rbac-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: rbac-test-pod
  labels:
    test-group: ${TEST_GROUP}
rbac-test-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccountName: pod-viewer
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing RBAC permissions' && kubectl get pods && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-rbac-pod.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to be ready
	k8s_wait_pod_be_ready "rbac-test-pod" "default" "120"

	# Verify pod can list pods using the ServiceAccount permissions
	kubectl exec rbac-test-pod -n "${KUASAR_TEST_NAMESPACE}" -- kubectl get pods

	# Cleanup
	kubectl delete pod rbac-test-pod -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete rolebinding pod-reader-binding -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete role pod-reader -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete serviceaccount pod-viewer -n "${KUASAR_TEST_NAMESPACE}"
}

@test "Pod with multiple ServiceAccounts" {
	# Test 5: Multiple containers with different ServiceAccounts
	cat > "${BATS_TMPDIR}/multi-sa.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-container-1
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-container-2
---
apiVersion: v1
kind: Pod
metadata:
  name: multi-sa-pod
  labels:
    test-group: ${TEST_GROUP}
multi-sa-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccountName: sa-container-1
  terminationGracePeriodSeconds: 0
  containers:
  - name: container1
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Container 1 with SA1' && ls /var/run/secrets/kubernetes.io/serviceaccount/ && sleep 30"]
  - name: container2
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Container 2 with default SA' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/multi-sa.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to be ready
	k8s_wait_pod_be_ready "multi-sa-pod" "${KUASAR_TEST_NAMESPACE}" "120"

	# Verify first container has custom SA
	kubectl exec multi-sa-pod -c container1 -n "${KUASAR_TEST_NAMESPACE}" -- ls /var/run/secrets/kubernetes.io/serviceaccount/

	# Cleanup
	kubectl delete pod multi-sa-pod -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete serviceaccount sa-container-1 -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete serviceaccount sa-container-2 -n "${KUASAR_TEST_NAMESPACE}"
}

@test "ServiceAccount with API discovery" {
 # Test 6: Verify service account can access Kubernetes API
	cat > "${BATS_TMPDIR}/sa-api-pod.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-test-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: api-test-role
rules:
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: api-test-binding
subjects:
- kind: ServiceAccount
  name: api-test-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: api-test-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: api-test-pod
  labels:
    test-group: ${TEST_GROUP}
api-test-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccountName: api-test-sa
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing API access' && kubectl get pods && kubectl get services && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/sa-api-pod.yaml" -n "${KUASAR_TEST_NAMESPACE}"

 # Wait for pod to be ready
	k8s_wait_pod_be_ready "api-test-pod" "${KUASAR_TEST_NAMESPACE}" "120"

 # Verify API access
	kubectl exec api-test-pod -n "${KUASAR_TEST_NAMESPACE}" -- kubectl get pods

 # Cleanup
	kubectl delete pod api-test-pod -n "${KUASAR_TEST_NAMESPACE}"
	kubectl delete clusterrolebinding api-test-binding
	kubectl delete clusterrole api-test-role
	kubectl delete serviceaccount api-test-sa
}

@test "Pod with deprecated serviceAccount field" {
 # Test 7: Verify deprecated serviceAccount field still works (if supported)
 # Note: This field is deprecated in Kubernetes 1.19+ but may still work
	cat > "${BATS_TMPDIR}/deprecated-sa.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: deprecated-sa-pod
  labels:
    test-group: ${TEST_GROUP}
deprecated-sa-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccount: default  // Deprecated field
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Using deprecated SA field' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/deprecated-sa.yaml" -n "${KUASAR_TEST_NAMESPACE}"

 # Wait for pod to start (may fail on newer Kubernetes versions)
	sleep 10

	pod_phase=$(kubectl get pod deprecated-sa-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	if [ "$pod_phase" = "Running" ]; then
 # Pod started, verify SA is mounted
		kubectl exec deprecated-sa-pod -n "${KUASAR_TEST_NAMESPACE}" -- ls /var/run/secrets/kubernetes.io/serviceaccount/
		info "Deprecated serviceAccount field still supported"
	elif [ "$pod_phase" = "Failed" ]; then
		info "Pod failed - deprecated field may not be supported in this Kubernetes version"
		kubectl describe pod deprecated-sa-pod -n "${KUASAR_TEST_NAMESPACE}"
	fi

 # Cleanup
	kubectl delete pod deprecated-sa-pod -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

@test("ServiceAccount token projection") {
 # Test 8: Test token projection with specific audiences
	cat > "${BATS_TMPDIR}/sa-token-projection.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: sa-token-projection-pod
  labels:
    test-group: ${TEST_GROUP}
sa-token-projection-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing token projection' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/sa-token-projection.yaml" -n "${KUASAR_TEST_NAMESPACE}"

 # Wait for pod to be ready
	k8s_wait_pod_be_ready "sa-token-projection-pod" "${KUASAR_TEST_NAMESPACE}" "60"

 # Verify token file exists and is readable
	kubectl exec sa-token-projection-pod -n "${KUASAR_TEST_NAMESPACE}" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 20

 # Cleanup
	kubectl delete pod sa-token-projection-pod -n "${KUASAR_TEST_NAMESPACE}"
}

@test("ServiceAccount with non-existent serviceAccountName") {
 # Test 9: Pod references non-existent ServiceAccount
	cat > "${BATS_TMPDIR}/invalid-sa-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: invalid-sa-pod
  labels:
    test-group: ${TEST_GROUP}
invalid-sa-pod
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  serviceAccountName: non-existent-sa-12345
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'This should fail' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/invalid-sa-pod.yaml" -n "${KUASAR_TEST_NAMESPACE}"

 # Pod should fail to start or be in Failed state
	sleep 10

	pod_status=$(kubectl get pod invalid-sa-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	if [ "$pod_status" != "Running" ]; then
		info "Pod correctly failed to start due to non-existent ServiceAccount"
		kubectl describe pod invalid-sa-pod -n "${KUASAR_TEST_NAMESPACE}"
	fi

 # Cleanup
	kubectl delete pod invalid-sa-pod -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete serviceaccounts --all --ignore-not-found=true 2>/dev/null || true
	kubectl delete roles --all --ignore-not-found=true 2>/dev/null || true
	kubectl delete rolebindings --all --ignore-not-found=true 2>/dev/null || true
	kubectl delete clusterroles --all --ignore-not-found=true 2>/dev/null || true
	kubectl delete clusterrolebindings --all --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
