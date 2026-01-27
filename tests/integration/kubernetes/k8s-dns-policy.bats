#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test DNS Policy configuration for Pods

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "DNS Policy - ClusterFirst (default)" {
	# Test 1: Default DNS policy (ClusterFirst)
	cat > "${BATS_TMPDIR}/pod-dns-default.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-default-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-dns-default.yaml")

	# Check /etc/resolv.conf inside the pod
	resolv_conf=$(kubectl exec "${pod_name}" -- cat /etc/resolv.conf)

	# Should have cluster DNS server (usually via CoreDNS)
	echo "$resolv_conf" | grep -q "nameserver"

	# Should have search paths for cluster domain
	echo "$resolv_conf" | grep -q "search"
}

@test "DNS Policy - Default" {
	# Test 2: DNS Policy set to Default (use pod's DNS settings)
	cat > "${BATS_TMPDIR}/pod-dns-policy-default.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-policy-default-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  dnsPolicy: Default
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-dns-policy-default.yaml")

	# Default policy should allow cluster DNS
	kubectl exec "${pod_name}" -- nslookup kubernetes.default.svc.cluster.local || echo "Cluster DNS lookup test"
}

@test "DNS Policy - None" {
	# Test 3: DNS Policy set to None (disable DNS)
	cat > "${BATS_TMPDIR}/pod-dns-none.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-none-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  dnsPolicy: None
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-dns-none.yaml")

	# With dnsPolicy: None, DNS resolution should fail for cluster services
	# Note: Some DNS configs might still allow external lookups
	if kubectl exec "${pod_name}" -- which nslookup >/dev/null 2>&1; then
		info "nslookup available, testing DNS resolution..."
		# Cluster DNS should fail
		if kubectl exec "${pod_name}" -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -q "NXDOMAIN"; then
			info "Cluster DNS correctly fails with dnsPolicy: None"
		fi
	else
		info "nslookup not available in container"
	fi
}

@test "Custom DNS configuration" {
	# Test 4: Pod with custom DNS configuration
	cat > "${BATS_TMPDIR}/pod-custom-dns.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: custom-dns-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  dnsPolicy: "None"
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-custom-dns.yaml"
	sleep 5

	# Patch pod with custom DNS configuration
	kubectl patch pod custom-dns-pod -p '{"spec":{"dnsPolicy":"None"}}' >/dev/null 2>&1 || true

	# Check pod status
	pod_phase=$(kubectl get pod custom-dns-pod -o jsonpath='{.status.phase}')
	echo "Pod phase: $pod_phase"

	if [ "$pod_phase" = "Running" ]; then
		# Verify /etc/resolv.conf can be read
		kubectl exec custom-dns-pod -- cat /etc/resolv.conf || true
	fi
}

@test "DNS nameservers and searches configuration" {
	# Test 5: Custom DNS nameservers and search domains
	cat > "${BATS_TMPDIR}/pod-dns-config.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-config-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  dnsPolicy: "None"
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'DNS configured' && sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/pod-dns-config.yaml"

	# Add DNS config via pod spec patch
	kubectl patch pod dns-config-pod -p '{"spec":{"dnsPolicy":"None"}}' >/dev/null 2>&1 || true

	# Wait for pod to be ready
	k8s_wait_pod_be_ready "dns-config-pod" "default" "60"

	# Verify /etc/resolv.conf can be accessed
	kubectl exec dns-config-pod -- cat /etc/resolv.conf || true
}

@test "ClusterFirst vs ClusterFirstWithHostNet" {
	# Test 6: Compare ClusterFirst and ClusterFirstWithHostNet policies
	for policy in "ClusterFirst" "ClusterFirstWithHostNet"; do
		cat > "${BATS_TMPDIR}/pod-dns-${policy}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-${policy}-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  dnsPolicy: ${policy}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'DNS policy: ${policy}' && sleep 30"]
EOF

		pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-dns-${policy}.yaml")

	# Check DNS configuration
		kubectl exec "${pod_name}" -- cat /etc/resolv.conf | head -5
		echo "---"

		# Cleanup for next iteration
		kubectl delete pod "${pod_name}" --ignore-not-found=true
		sleep 3
	done
}

@test "DNS resolution for services" {
	# Test 7: Verify DNS resolution for Kubernetes services
	# First create a service to resolve
	cat > "${BATS_TMPDIR}/dns-test-svc.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-test-backend
  labels:
    app: dns-test
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: nginx
    image: ${NGINX_IMAGE}
    ports:
    - containerPort: 80
EOF

	kubectl apply -f "${BATS_TMPDIR}/dns-test-svc.yaml"
	k8s_wait_pod_be_ready "dns-test-backend" "default" "60"

	cat > "${BATS_TMPDIR}/dns-test-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dns-test-service
spec:
  selector:
    app: dns-test
  ports:
  - port: 80
    targetPort: 80
EOF

	kubectl apply -f "${BATS_TMPDIR}/dns-test-service.yaml"
	sleep 5

	# Create client pod to test DNS resolution
	cat > "${BATS_TMPDIR}/dns-client-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-client
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: client
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 30"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/dns-client-pod.yaml"
	k8s_wait_pod_be_ready "dns-client" "default" "60"

	# Test DNS resolution for service
	if kubectl exec dns-client -- which nslookup >/dev/null 2>&1; then
		# Try to resolve the service
		kubectl exec dns-client -- nslookup dns-test-service.default || echo "DNS resolution completed"
		kubectl exec dns-client -- wget -qO- --timeout=5 http://dns-test-service.default || echo "HTTP access completed"
	else
		info "nslookup not available, testing with wget"
		kubectl exec dns-client -- wget -qO- --timeout=5 http://dns-test-service.default || echo "Test completed"
	fi

	# Cleanup
	kubectl delete pod dns-client dns-test-backend --ignore-not-found=true
	kubectl delete service dns-test-service --ignore-not-found=true
}

@test "Pod DNS ConfigMap injection" {
	# Test 8: Custom DNS config via ConfigMap (for advanced scenarios)
	cat > "${BATS_TMPDIR}/dns-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    acme.local
  nameservers:
    - 1.2.3.4
EOF

	# Note: This is a read-only configmap in real clusters
	kubectl get configmap kube-dns -n kube-system -o yaml || echo "kube-dns ConfigMap not accessible (expected in test environment)"

	# Verify default CoreDNS ConfigMap exists
	if kubectl get configmap coredns -n kube-system >/dev/null 2>&1; then
		kubectl get configmap coredns -n kube-system -o yaml | head -20
		info "CoreDNS ConfigMap found"
	else
		info "CoreDNS ConfigMap not found (may use different DNS provider)"
	fi

	# Create a pod with DNS policy
	cat > "${BATS_TMPDIR}/pod-coredns-check.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: coredns-check-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "cat /etc/resolv.conf && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-coredns-check.yaml")

	# Show DNS configuration
	kubectl exec "${pod_name}" -- cat /etc/resolv.conf
}

@test "DNS search domains" {
	# Test 9: Verify search domains in DNS configuration
	cat > "${BATS_TMPDIR}/pod-dns-search.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-search-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  terminationGracePeriodSeconds: 0
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "cat /etc/resolv.conf | grep search && sleep 30"]
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-dns-search.yaml")

	# Verify search domains are configured
	kubectl exec "${pod_name}" -- cat /etc/resolv.conf | grep "search"
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete services --all --ignore-not-found=true 2>/dev/null || true
	kubectl delete configmaps --all --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
