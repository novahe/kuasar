#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test pod-to-pod communication via Kubernetes Service

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"

	# Check CoreDNS status
	local coredns_ready=$(kubectl get pod -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
	info "CoreDNS status: $coredns_ready pod(s) Running"
	kubectl get pod -n kube-system -l k8s-app=kube-dns
}

@test "Pod to pod communication via ClusterIP service" {
	# Test 1: Create a simple nginx server pod
	cat > "${BATS_TMPDIR}/server-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx-server
  labels:
    test-group: ${TEST_GROUP}
    app: nginx-server
    role: backend
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: nginx
    image: ${NGINX_IMAGE}
    ports:
    - containerPort: 80
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/server-pod.yaml"

	# Wait for server pod to be ready
	k8s_wait_pod_be_ready "nginx-server" "${KUASAR_TEST_NAMESPACE}" "120"

	# Create a ClusterIP service
	cat > "${BATS_TMPDIR}/nginx-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx-server
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/nginx-service.yaml"

	# Wait for service to be created
	sleep 5

	# Get cluster IP
	service_ip=$(kubectl get service nginx-service -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
	[ -n "$service_ip" ]

	info "Nginx service ClusterIP: $service_ip"

	# Create client pod to test connectivity
	cat > "${BATS_TMPDIR}/client-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: busybox-client
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${BUSYBOX_IMAGE}
    command: ["tail", "-f", "/dev/null"]
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/client-pod.yaml"

	# Wait for client pod to be ready
	k8s_wait_pod_be_ready "busybox-client" "${KUASAR_TEST_NAMESPACE}" "120"

	# Test 1: Access server via ClusterIP
	info "Test 1: Access via ClusterIP"
	output=$(kubectl exec -n "${KUASAR_TEST_NAMESPACE}" busybox-client -- wget -qO- http://$service_ip:80 2>&1 || echo "Failed")
	echo "$output" | grep -q "Welcome to nginx\|nginx"

	# Test 2: Access server via service name (DNS resolution)
	info "Test 2: Access via service name (DNS)"
	output=$(kubectl exec -n "${KUASAR_TEST_NAMESPACE}" busybox-client -- wget -qO- http://nginx-service:80 2>&1 || echo "Failed")
	echo "$output" | grep -q "Welcome to nginx\|nginx"

	# Test 3: Access server via service FQDN
	info "Test 3: Access via FQDN"
	output=$(kubectl exec -n "${KUASAR_TEST_NAMESPACE}" busybox-client -- wget -qO- http://nginx-service.${KUASAR_TEST_NAMESPACE}.svc.cluster.local:80 2>&1 || echo "Failed")
	echo "$output" | grep -q "Welcome to nginx\|nginx"

	# Cleanup for this test
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod busybox-client
}

@test "Multiple client pods accessing same backend service" {
	# Test 2: Multiple client pods accessing the same service
	info "Creating multiple client pods..."

	for i in 1 2 3; do
		cat > "${BATS_TMPDIR}/client-pod-${i}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client-pod-${i}
  labels:
    test-group: ${TEST_GROUP}
    app: client
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo Client \${HOSTNAME} ready && tail -f /dev/null"]
EOF
		kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/client-pod-${i}.yaml"
	done

	# Wait for all clients to be ready
	for i in 1 2 3; do
		k8s_wait_pod_be_ready "client-pod-${i}" "${KUASAR_TEST_NAMESPACE}" "120"
	done

	# Test connectivity from all clients
	info "Testing connectivity from all clients..."
	for i in 1 2 3; do
		output=$(kubectl exec -n "${KUASAR_TEST_NAMESPACE}" client-pod-${i} -- wget -qO- http://nginx-service:80 2>&1)
		echo "$output" | grep -q "Welcome to nginx\|nginx"
		info "client-pod-${i}: SUCCESS"
	done

	# Cleanup
	for i in 1 2 3; do
		kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod "client-pod-${i}"
	done
}

@test "Service with multiple endpoints" {
	# Test 3: Service with multiple backend pods
	info "Creating multiple backend pods..."

	# Create 3 nginx server pods
	for i in 1 2 3; do
		cat > "${BATS_TMPDIR}/backend-pod-${i}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx-backend-${i}
  labels:
    test-group: ${TEST_GROUP}
    app: nginx-backend
    pod: "${i}"
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: nginx
    image: ${NGINX_IMAGE}
    ports:
    - containerPort: 80
    env:
    - name: POD_NAME
      value: "nginx-backend-${i}"
EOF
		kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/backend-pod-${i}.yaml"
	done

	# Wait for all backends to be ready
	for i in 1 2 3; do
		k8s_wait_pod_be_ready "nginx-backend-${i}" "${KUASAR_TEST_NAMESPACE}" "120"
	done

	# Create service for backends
	cat > "${BATS_TMPDIR}/backend-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: backend-service
spec:
  selector:
    app: nginx-backend
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 80
  type: ClusterIP
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/backend-service.yaml"

	sleep 5

	# Create client to test load balancing
	cat > "${BATS_TMPDIR}/test-client.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-client
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "tail -f /dev/null"]
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/test-client.yaml"
	k8s_wait_pod_be_ready "test-client" "${KUASAR_TEST_NAMESPACE}" "120"

	# Test service endpoints
	kubectl get endpoints backend-service -n "${KUASAR_TEST_NAMESPACE}"

	# Access service multiple times to test load balancing
	info "Testing service load balancing..."
	success_count=0
	for i in 1 2 3 4 5; do
		output=$(kubectl exec -n "${KUASAR_TEST_NAMESPACE}" test-client -- wget -qO- http://backend-service:8080 2>&1)
		if echo "$output" | grep -q "Welcome to nginx\|nginx"; then
			success_count=$((success_count + 1))
		fi
	done

	# Should succeed at least some times
	[ "$success_count" -ge 3 ]

	# Cleanup client
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod test-client

	# Cleanup backends and service
	for i in 1 2 3; do
		kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod "nginx-backend-${i}"
	done
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true service backend-service
}

@test "Headless service for direct pod access" {
	# Test 4: Headless service (ClusterIP: None) for direct pod access
	cat > "${BATS_TMPDIR}/headless-backend.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: headless-backend
  labels:
    test-group: ${TEST_GROUP}
    app: headless-app
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: server
    image: ${BUSYBOX_IMAGE}
    command: ["nc", "-l", "-p", "8080", "-e", "echo 'Hello from headless-backend'"]
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/headless-backend.yaml"
	k8s_wait_pod_be_ready "headless-backend" "${KUASAR_TEST_NAMESPACE}" "120"

	# Create headless service
	cat > "${BATS_TMPDIR}/headless-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: headless-service
spec:
  clusterIP: None
  selector:
    app: headless-app
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 8080
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/headless-service.yaml"
	sleep 5

	# Check DNS resolution for headless service
	cat > "${BATS_TMPDIR}/dns-test-client.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-client
  labels:
    test-group: ${TEST_GROUP}
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${BUSYBOX_IMAGE}
    command: ["tail", "-f", "/dev/null"]
EOF

	kubectl apply -n "${KUASAR_TEST_NAMESPACE}" -f "${BATS_TMPDIR}/dns-test-client.yaml"
	k8s_wait_pod_be_ready "dns-client" "${KUASAR_TEST_NAMESPACE}" "120"

	# Test DNS lookup for headless service
	info "Testing DNS resolution for headless service..."
	kubectl exec -n "${KUASAR_TEST_NAMESPACE}" dns-client -- nslookup headless-service.${KUASAR_TEST_NAMESPACE}.svc.cluster.local

	# Cleanup
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod dns-client
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true service headless-service
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true pod headless-backend
}

teardown() {
	info "Cleaning up service-related resources..."
	k8s_delete_all_pods || true
	kubectl delete -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true services --all --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
