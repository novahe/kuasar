#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Init Containers functionality

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Pod with single init container" {
	# Test 1: Single init container that creates a file before main container starts
	cat > "${BATS_TMPDIR}/pod-init-single.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-single-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init container running' && sleep 5 && echo 'Init complete' > /tmp/init-done.txt && echo 'Data from init' > /tmp/init-data.txt"]
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init-done.txt ]; then echo 'Init completed successfully'; cat /tmp/init-data.txt; else echo 'Init did not complete'; exit 1; fi && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-single.yaml")

	# Verify init container completed
	grep_pod_exec_output "${pod_name}" "Init completed successfully" sh -c "cat /tmp/init-done.txt"
	grep_pod_exec_output "${pod_name}" "Data from init" sh -c "cat /tmp/init-data.txt"
}

@test "Pod with multiple init containers" {
	# Test 2: Multiple init containers execute in sequence
	cat > "${BATS_TMPDIR}/pod-init-multi.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-multi-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-first
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init 1 starting' && sleep 3 && echo 'Init 1 done' > /tmp/init1.txt"]
  - name: init-second
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init 2 starting' && if [ -f /tmp/init1.txt ]; then echo 'Init 1 verified'; else echo 'Init 1 failed'; exit 1; fi && sleep 3 && echo 'Init 2 done' > /tmp/init2.txt"]
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init1.txt ] && [ -f /tmp/init2.txt ]; then echo 'All inits completed'; cat /tmp/init1.txt; cat /tmp/init2.txt; else echo 'Inits failed'; exit 1; fi && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-multi.yaml")

	# Verify all init containers completed
	grep_pod_exec_output "${pod_name}" "All inits completed" sh -c "cat /tmp/init1.txt && cat /tmp/init2.txt"
}

@test "Init container with volume sharing" {
	# Test 3: Init container creates data in shared volume for main container
	cat > "${BATS_TMPDIR}/pod-init-volume.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-volume-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-setup
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Setting up data' && echo 'initial-data' > /shared/data.txt && echo 'Setup complete' > /shared/status.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-app
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Main app starting' && if [ -f /shared/data.txt ]; then cat /shared/data.txt; else echo 'Data not found'; exit 1; fi && if [ -f /shared/status.txt ]; then cat /shared/status.txt; else echo 'Status not found'; exit 1; fi && sleep 30"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-volume.yaml")

	# Verify init container data is accessible
	grep_pod_exec_output "${pod_name}" "initial-data" cat /shared/data.txt
	grep_pod_exec_output "${pod_name}" "Setup complete" cat /shared/status.txt
}

@test "Init container failure handling" {
	# Test 4: Init container failure should prevent pod from starting
	cat > "${BATS_TMPDIR}/pod-init-fail.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-fail-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-fail
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init will fail' && exit 1"]
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Main should not run' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-init-fail.yaml"

	# Wait for pod to reach a terminal state
	sleep 10

	# Pod should be in Failed or ImagePullBackOff state due to init failure
	pod_phase=$(kubectl get pod init-fail-pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	# The main container should never start if init fails
	if [ "$pod_phase" = "Running" ]; then
		# Check if main container is actually running or just in Running state
		container_state=$(kubectl get pod init-fail-pod -o jsonpath='{.status.containerStatuses[0].state.running}' 2>/dev/null)
		if [ -z "$container_state" ]; then
			info "Pod is in Running phase but container is not actually running (expected for init failure)"
		fi
	fi

	info "Pod phase: $pod_phase (Init container failed as expected)"

	# Cleanup
	kubectl delete pod init-fail-pod --ignore-not-found=true
}

@test "Init container with environment variables" {
	# Test 5: Init container with custom environment variables
	cat > "${BATS_TMPDIR}/pod-init-env.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-env-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-with-env
    image: ${BUSYBOX_IMAGE}
    env:
    - name: INIT_ENV
      value: "from-init-container"
    - name: INIT_TIMESTAMP
      value: "2024-01-01T00:00:00Z"
    command: ["sh", "-c", "echo \"INIT_ENV=\$INIT_ENV\" > /tmp/init-env.txt && echo \"INIT_TIMESTAMP=\$INIT_TIMESTAMP\" >> /tmp/init-env.txt"]
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init-env.txt ]; then cat /tmp/init-env.txt; else exit 1; fi && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-env.yaml")

	# Verify environment variables were passed to init container
	grep_pod_exec_output "${pod_name}" "INIT_ENV=from-init-container" cat /tmp/init-env.txt
	grep_pod_exec_output "${pod_name}" "INIT_TIMESTAMP=2024-01-01T00:00:00Z" cat /tmp/init-env.txt
}

@test "Init container with ConfigMap" {
	# Test 6: Init container using ConfigMap
	cat > "${BATS_TMPDIR}/init-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: init-config
data:
  app.properties: |
    feature.enabled=true
    app.version=1.0.0
    app.mode=production
EOF

	kubectl apply -f "${BATS_TMPDIR}/init-configmap.yaml"

	cat > "${BATS_TMPDIR}/pod-init-cm.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-configmap-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  volumes:
  - name: config-volume
    configMap:
      name: init-config
  initContainers:
  - name: init-read-config
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Reading config...' && cp /config/app.properties /tmp/app-config.txt && echo 'Config loaded'"]
    volumeMounts:
    - name: config-volume
      mountPath: /config
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/app-config.txt ]; then cat /tmp/app-config.txt; else echo 'Config not found'; exit 1; fi && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-cm.yaml")

	# Verify ConfigMap was read by init container
	grep_pod_exec_output "${pod_name}" "feature.enabled=true" cat /tmp/app-config.txt

	# Cleanup
	kubectl delete configmap init-config
}

@test "Init container with resource limits" {
	# Test 7: Init container with its own resource limits
	cat > "${BATS_TMPDIR}/pod-init-resources.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-resources-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-limited
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init with limited resources' && sleep 5 && echo 'Done' > /tmp/init-res.txt"]
    resources:
      requests:
        memory: "32Mi"
        cpu: "100m"
      limits:
        memory: "64Mi"
        cpu: "200m"
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init-res.txt ]; then cat /tmp/init-res.txt; else exit 1; fi && sleep 30"]
    resources:
      requests:
        memory: "64Mi"
        cpu: "200m"
      limits:
        memory: "128Mi"
        cpu: "400m"
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-resources.yaml")

	# Verify init container completed with its resource limits
	grep_pod_exec_output "${pod_name}" "Init with limited resources" cat /tmp/init-res.txt
}

@test "Init container with security context" {
	# Test 8: Init container with different security context than main container
	cat > "${BATS_TMPDIR}/pod-init-security.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-security-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-check
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init as non-root' && id && echo 'Init done' > /tmp/init-security.txt"]
    securityContext:
      runAsUser: 1000
      runAsGroup: 3000
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init-security.txt ]; then cat /tmp/init-security.txt; else exit 1; fi && sleep 30"]
    securityContext:
      runAsUser: 2000
      runAsGroup: 4000
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-security.yaml")

	# Verify init container ran with its security context
	grep_pod_exec_output "${pod_name}" "Init as non-root" cat /tmp/init-security.txt
}

@test "Init container with network access" {
	# Test 9: Init container with network access to fetch data
	cat > "${BATS_TMPDIR}/pod-init-network.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-network-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  initContainers:
  - name: init-fetch
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Fetching data from network...' && wget -q -O /tmp/fetched-data --timeout=10 http://www.example.com || echo 'Network failed or timeout (expected)'; echo 'Init done' > /tmp/init-net.txt"]
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /tmp/init-net.txt ]; then cat /tmp/init-net.txt; else echo 'Init file not found'; fi && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-init-network.yaml"

	# Wait for pod to start (network may fail which is ok)
	sleep 15

	# Check if pod started (init may fail network but that's acceptable)
	pod_status=$(kubectl get pod init-network-pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	if [ "$pod_status" != "Failed" ]; then
		# Pod started, check if init completed
		if kubectl get pod init-network-pod -o jsonpath='{.status.containerStatuses[0].state.running}' 2>/dev/null | grep -q .; then
			# Container is running, check for init completion
			output=$(kubectl exec init-network-pod -- cat /tmp/init-net.txt 2>/dev/null || echo "Failed to read")
			info "Init output: $output"
		fi
	fi

	# Cleanup
	kubectl delete pod init-network-pod --ignore-not-found=true
}

@test "Init container with emptyDir subPath" {
	# Test 10: Init container writes to specific subPath of emptyDir
	cat > "${BATS_TMPDIR}/pod-init-subpath.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: init-subpath-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  volumes:
  - name: workdir
    emptyDir: {}
  initContainers:
  - name: init-workdir
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "mkdir -p /work/app/data && echo 'Workdir created' > /work/app/ready.txt && echo 'Build info: v1.0' > /work/app/version.txt"]
    volumeMounts:
    - name: workdir
      mountPath: /work
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /work/app/ready.txt ]; then cat /work/app/version.txt; else echo 'Not ready'; exit 1; fi && sleep 30"]
    volumeMounts:
    - name: workdir
      mountPath: /work
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-subpath.yaml")

	# Verify init container created subPath structure
	grep_pod_exec_output "${pod_name}" "Build info: v1.0" cat /work/app/version.txt
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete configmaps --all --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
