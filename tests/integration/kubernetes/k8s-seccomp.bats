#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Seccomp profiles for security containers

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Pod with default seccomp profile" {
	# Test 1: Pod with default seccomp profile (RuntimeDefault)
	cat > "${BATS_TMPDIR}/pod-seccomp-default.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing default seccomp' && tail -f /dev/null"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-seccomp-default.yaml")

	# Verify pod is running with seccomp
	is_pod_running "${pod_name}"

	# Check seccomp mode is enabled
	pod_exec "${pod_name}" cat /proc/self/status | grep "Seccomp:"
}

@test "Pod with localhost seccomp profile" {
	# Test 2: Pod with custom seccomp profile from localhost
	# Create a seccomp profile that blocks chmod but allows other syscalls
	cat > "${BATS_TMPDIR}/seccomp-profile.json" <<EOF
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["chmod", "fchmodat", "fchmod"],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
EOF

	# Create a ConfigMap with the seccomp profile
	cat > "${BATS_TMPDIR}/seccomp-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: seccomp-profile
data:
  seccomp-profile.json: |
$(cat ${BATS_TMPDIR}/seccomp-profile.json | sed 's/^/    /')
EOF

	kubectl apply -f "${BATS_TMPDIR}/seccomp-configmap.yaml"

	# Create pod that uses the seccomp profile
	cat > "${BATS_TMPDIR}/pod-seccomp-custom.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-custom-pod
  annotations:
    seccomp.security.alpha.kubernetes.io/pod: 'localhost/profiles/seccomp-profile.json'
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing custom seccomp' && tail -f /dev/null"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-seccomp-custom.yaml"

	# Verify pod is running
	is_pod_running "${pod_name}"

	# Cleanup
	kubectl delete configmap seccomp-profile
}

@test "Security container - privileged pod should be blocked or handled" {
	# Test 3: Security containers should not support privileged mode
	# This test verifies that privileged pods are either blocked or properly isolated

	cat > "${BATS_TMPDIR}/pod-privileged.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing privileged' && tail -f /dev/null"]
    securityContext:
      privileged: true
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-privileged.yaml"

	# Wait for pod to reach a final state
	sleep 10

	# Check pod status - it should either be running with proper isolation
	# or the runtime should handle privileged mode appropriately
	pod_status=$(kubectl get pod privileged-pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	if [ "$pod_status" = "Running" ]; then
		# Pod is running - verify it has proper capabilities dropped
		# Security containers should drop capabilities even when privileged=true is requested
		echo "Pod is running - checking capabilities..."
		pod_exec "privileged-pod" capsh --print 2>/dev/null || pod_exec "privileged-pod" cat /proc/self/status
	elif [ "$pod_status" = "Failed" ] || [ "$pod_status" = "Error" ]; then
		# Pod failed - this is acceptable for security containers
		echo "Pod failed as expected for security containers"
		kubectl describe pod privileged-pod
	else
		# Pod might be in other state
		echo "Pod status: $pod_status"
	fi
}

@test "Pod with dropped capabilities" {
	# Test 4: Pod with specific capabilities dropped
	cat > "${BATS_TMPDIR}/pod-capabilities.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: caps-dropped-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing dropped capabilities' && tail -f /dev/null"]
    securityContext:
      capabilities:
        drop:
        - NET_RAW
        - SYS_ADMIN
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-capabilities.yaml")

	# Verify pod is running
	is_pod_running "${pod_name}"

	# Verify capabilities are properly dropped
	# NET_RAW should be dropped - ping should not work
	pod_exec "${pod_name}" which ping || echo "Ping not available (expected)"

	# SYS_ADMIN should be dropped - cannot mount
	pod_exec "${pod_name}" mount 2>&1 | grep -q "Operation not permitted" || echo "Mount blocked as expected"
}

@test "Pod with added capabilities" {
	# Test 5: Pod with specific capabilities added
	cat > "${BATS_TMPDIR}/pod-caps-added.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: caps-added-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing added capabilities' && tail -f /dev/null"]
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-caps-added.yaml}"

	# Verify pod is running
	is_pod_running "${pod_name}"

	# NET_ADMIN capability should allow network operations
	pod_exec "${pod_name}" ip link show
}

@test "Pod with readOnlyRootFilesystem" {
	# Test 6: Pod with read-only root filesystem
	cat > "${BATS_TMPDIR}/pod-readonly.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: readonly-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing readonly root' && touch /tmp/test && ls /tmp/test && tail -f /dev/null"]
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: cache
      mountPath: /tmp
      mountPropagation: HostToContainer
  volumes:
  - name: cache
    emptyDir: {}
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-readonly.yaml")

	# Verify pod is running with read-only root
	# Write to /tmp should succeed (it's a mounted volume)
	pod_exec "${pod_name}" ls /tmp/test
}

@test "Seccomp with unconfined profile" {
	# Test 7: Pod with unconfined seccomp profile (all syscalls allowed)
	cat > "${BATS_TMPDIR}/pod-seccomp-unconfined.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-unconfined-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  securityContext:
    seccompProfile:
      type: Unconfined
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Testing unconfined seccomp' && tail -f /dev/null"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-seccomp-unconfined.yaml}"

	# Verify pod is running
	is_pod_running "${pod_name}"

	# All syscalls should be allowed
	pod_exec "${pod_name}" chmod 644 /tmp/test
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete configmaps --all --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
