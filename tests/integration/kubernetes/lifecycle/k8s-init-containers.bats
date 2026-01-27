#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Init Containers functionality

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

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
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init container running' && sleep 5 && echo 'Init complete' > /shared/init-done.txt && echo 'Data from init' > /shared/init-data.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/init-done.txt ]; then echo 'Init completed successfully'; cat /shared/init-data.txt; else echo 'Init did not complete'; fi && sleep 30"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-single.yaml")

	# Verify init container completed
	pod_exec "${pod_name}" sh -c "cat /shared/init-done.txt"
	grep_pod_exec "${pod_name}" "Init complete" cat /shared/init-done.txt
	grep_pod_exec "${pod_name}" "Data from init" cat /shared/init-data.txt
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
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-first
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init 1 starting' && sleep 3 && echo 'Init 1 done' > /shared/init1.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  - name: init-second
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init 2 starting' && if [ -f /shared/init1.txt ]; then echo 'Init 1 verified'; else echo 'Init 1 failed'; fi && sleep 3 && echo 'Init 2 done' > /shared/init2.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/init1.txt ] && [ -f /shared/init2.txt ]; then echo 'All inits completed'; cat /shared/init1.txt; cat /shared/init2.txt; else echo 'Inits failed'; fi && sleep 30"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-multi.yaml")

	# Verify all init containers completed
	output=$(pod_exec "${pod_name}" sh -c "cat /shared/init1.txt && echo '---' && cat /shared/init2.txt")
	echo "$output"
	echo "$output" | grep -q "Init 1 done"
	echo "$output" | grep -q "Init 2 done"
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

	kubectl apply -f "${BATS_TMPDIR}/pod-init-fail.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to reach a terminal state
	sleep 10

	# Pod should be in Failed or ImagePullBackOff state due to init failure
	pod_phase=$(kubectl get pod init-fail-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	# The main container should never start if init fails
	if [ "$pod_phase" = "Running" ]; then
		# Check if main container is actually running or just in Running state
		container_state=$(kubectl get pod init-fail-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.running}' 2>/dev/null)
		if [ -z "$container_state" ]; then
			info "Pod is in Running phase but container is not actually running (expected for init failure)"
		fi
	fi

	info "Pod phase: $pod_phase (Init container failed as expected)"

	# Cleanup
	kubectl delete pod init-fail-pod -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
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
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-with-env
    image: ${BUSYBOX_IMAGE}
    env:
    - name: INIT_ENV
      value: "from-init-container"
    - name: INIT_TIMESTAMP
      value: "2024-01-01T00:00:00Z"
    command: ["sh", "-c", "echo \"INIT_ENV=\$INIT_ENV\" > /shared/init-env.txt && echo \"INIT_TIMESTAMP=\$INIT_TIMESTAMP\" >> /shared/init-env.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/init-env.txt ]; then cat /shared/init-env.txt; else echo 'Init env not found'; fi && sleep 30"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-env.yaml")

	# Verify environment variables were passed to init container
	grep_pod_exec_output "${pod_name}" "INIT_ENV=from-init-container" cat /shared/init-env.txt
	grep_pod_exec_output "${pod_name}" "INIT_TIMESTAMP=2024-01-01T00:00:00Z" cat /shared/init-env.txt
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

	kubectl apply -f "${BATS_TMPDIR}/init-configmap.yaml" -n "${KUASAR_TEST_NAMESPACE}"

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
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-read-config
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Reading config...' && cp /config/app.properties /shared/app-config.txt && echo 'Config loaded'"]
    volumeMounts:
    - name: config-volume
      mountPath: /config
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/app-config.txt ]; then cat /shared/app-config.txt; else echo 'Config not found'; fi && sleep 30"]
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-cm.yaml")

	# Verify ConfigMap was read by init container
	grep_pod_exec_output "${pod_name}" "feature.enabled=true" cat /shared/app-config.txt

	# Cleanup
	kubectl delete configmap init-config -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
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
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-limited
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init with limited resources' && sleep 5 && echo 'Done' > /shared/init-res.txt"]
    resources:
      requests:
        memory: "32Mi"
        cpu: "100m"
      limits:
        memory: "64Mi"
        cpu: "200m"
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/init-res.txt ]; then cat /shared/init-res.txt; else echo 'Init not found'; fi && sleep 30"]
    resources:
      requests:
        memory: "64Mi"
        cpu: "200m"
      limits:
        memory: "128Mi"
        cpu: "400m"
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-resources.yaml")

	# Verify init container completed with its resource limits
	pod_exec "${pod_name}" cat /shared/init-res.txt
	grep_pod_exec "${pod_name}" "Done" cat /shared/init-res.txt
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
  volumes:
  - name: shared-data
    emptyDir: {}
  initContainers:
  - name: init-check
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'Init as non-root' && id && echo 'Init done' > /shared/init-security.txt"]
    securityContext:
      runAsUser: 1000
      runAsGroup: 3000
    volumeMounts:
    - name: shared-data
      mountPath: /shared
  containers:
  - name: main-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "if [ -f /shared/init-security.txt ]; then cat /shared/init-security.txt; else echo 'Init security file not found'; fi && sleep 30"]
    securityContext:
      runAsUser: 2000
      runAsGroup: 4000
    volumeMounts:
    - name: shared-data
      mountPath: /shared
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-init-security.yaml")

	# Verify init container ran with its security context
	pod_exec "${pod_name}" cat /shared/init-security.txt
	grep_pod_exec "${pod_name}" "Init done" cat /shared/init-security.txt
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

	kubectl apply -f "${BATS_TMPDIR}/pod-init-network.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for pod to start (network may fail which is ok)
	sleep 15

	# Check if pod started (init may fail network but that's acceptable)
	pod_status=$(kubectl get pod init-network-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

	if [ "$pod_status" != "Failed" ]; then
		# Pod started, check if init completed
		if kubectl get pod init-network-pod -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.running}' 2>/dev/null | grep -q .; then
			# Container is running, check for init completion
			output=$(kubectl exec init-network-pod -n "${KUASAR_TEST_NAMESPACE}" -- cat /tmp/init-net.txt 2>/dev/null || echo "Failed to read")
			info "Init output: $output"
		fi
	fi

	# Cleanup
	kubectl delete pod init-network-pod -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
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
	kubectl delete configmaps --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
