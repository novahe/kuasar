#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Kubernetes Deployment with upgrade and rollback

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Deployment creation and scaling" {
	# Create a deployment
	cat > "${BATS_TMPDIR}/test-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: test
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      containers:
      - name: test-container
        image: ${NGINX_IMAGE}
        command: ["sh", "-c", "echo 'Running v1'; sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for deployment to be ready
	kubectl rollout status deployment/test-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Verify all replicas are ready
	ready=$(kubectl get deployment test-deployment -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
	[ "$ready" = "2" ]

	# Scale up to 3 replicas
	kubectl scale deployment/test-deployment -n "${KUASAR_TEST_NAMESPACE}" --replicas=3
	kubectl rollout status deployment/test-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	ready=$(kubectl get deployment test-deployment -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
	[ "$ready" = "3" ]

	# Scale down to 1 replica
	kubectl scale deployment/test-deployment -n "${KUASAR_TEST_NAMESPACE}" --replicas=1
	kubectl rollout status deployment/test-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	ready=$(kubectl get deployment test-deployment -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
	[ "$ready" = "1" ]
}

@test "Deployment rolling update" {
	# Create initial deployment (v1)
	cat > "${BATS_TMPDIR}/rolling-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rolling
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: rolling
        version: v1
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 5
      containers:
      - name: rolling-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'Version 1.0' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/rolling-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/rolling-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Verify v1 is running
	v1_pod=$(kubectl get pods -l app=rolling,version=v1 -n "${KUASAR_TEST_NAMESPACE}" -o name | head -1 | sed 's/pod\///')
	[ -n "$v1_pod" ]
	logs=$(kubectl logs "$v1_pod" -n "${KUASAR_TEST_NAMESPACE}" | grep "Version 1.0")
	[ -n "$logs" ]

	# Update to v2
	cat > "${BATS_TMPDIR}/rolling-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rolling
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: rolling
        version: v2
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 5
      containers:
      - name: rolling-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'Version 2.0' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/rolling-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for rolling update to complete
	kubectl rollout status deployment/rolling-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=180s

	# Wait a bit for all old pods to be fully terminated
	sleep 5

	# Verify v2 is running
	v2_pods=$(kubectl get pods -l app=rolling,version=v2 -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}')
	[ -n "$v2_pods" ]

	# Check we have exactly 3 v2 pods
	v2_count=$(kubectl get pods -l app=rolling,version=v2 -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' | wc -w)
	[ "$v2_count" = "3" ]

	# Verify v2 content
	for pod in $(echo "$v2_pods"); do
		log=$(kubectl logs "$pod" -n "${KUASAR_TEST_NAMESPACE}" | grep "Version 2.0")
		[ -n "$log" ]
	done
}

@test "Deployment rollback" {
	# Create deployment (v1)
	cat > "${BATS_TMPDIR}/rollback-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rollback-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: rollback
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: rollback
        version: v1
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 5
      containers:
      - name: rollback-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'Stable version 1.0' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/rollback-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/rollback-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Save initial revision
	revision_history=$(kubectl rollout history deployment/rollback-deployment -n "${KUASAR_TEST_NAMESPACE}")
	[ -n "$revision_history" ]

	# Update to v2 (potentially problematic)
	cat > "${BATS_TMPDIR}/rollback-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rollback-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: rollback
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: rollback
        version: v2
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 5
      containers:
      - name: rollback-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'New version 2.0' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/rollback-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/rollback-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Verify v2 is deployed
	v2_pods=$(kubectl get pods -l app=rollback,version=v2 -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}')
	[ -n "$v2_pods" ]

	# Rollback to v1
	kubectl rollout undo deployment/rollback-deployment -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/rollback-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=180s

	# Wait for all old pods to be fully terminated
	sleep 5

	# Verify rollback to v1
	v1_pods=$(kubectl get pods -l app=rollback,version=v1 -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}')
	[ -n "$v1_pods" ]

	# Check we have exactly 2 v1 pods
	v1_count=$(kubectl get pods -l app=rollback,version=v1 -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' | wc -w)
	[ "$v1_count" = "2" ]

	# Verify v1 content after rollback
	for pod in $(echo "$v1_pods"); do
		log=$(kubectl logs "$pod" -n "${KUASAR_TEST_NAMESPACE}" | grep "Stable version 1.0")
		[ -n "$log" ]
	done
}

@test "Deployment revision history" {
	# Create deployment
	cat > "${BATS_TMPDIR}/history-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: history-deployment
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: history
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: history
        version: v1
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      containers:
      - name: history-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'v1' && sleep 60"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/history-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/history-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=60s

	# Create multiple updates
	for version in 2 3 4; do
		cat > "${BATS_TMPDIR}/history-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: history-deployment
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: history
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: history
        version: v${version}
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      containers:
      - name: history-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'v${version}' && sleep 60"]
EOF
		kubectl apply -f "${BATS_TMPDIR}/history-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
		kubectl rollout status deployment/history-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=60s
	done

	# Check revision history exists
	history=$(kubectl rollout history deployment/history-deployment -n "${KUASAR_TEST_NAMESPACE}")
	[ -n "$history" ]

	# Verify we can see revisions (check for REVISION or revision in output)
	if echo "$history" | grep -q "REVISION"; then
		# Count the number of revision lines (excluding header)
		revisions=$(echo "$history" | grep -c "^[0-9]")
	else
		# Fallback: check if there are multiple updates recorded
		revisions=$(kubectl rollout history deployment/history-deployment -n "${KUASAR_TEST_NAMESPACE}" | grep -c "revision")
	fi
	[ "$revisions" -ge 2 ]
}

@test "Deployment with paused rollout" {
	# Create deployment
	cat > "${BATS_TMPDIR}/paused-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paused-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: paused
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: paused
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      containers:
      - name: paused-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'Initial' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/paused-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/paused-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Pause the deployment
	kubectl rollout pause deployment/paused-deployment -n "${KUASAR_TEST_NAMESPACE}"

	# Update while paused
	cat > "${BATS_TMPDIR}/paused-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paused-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: paused
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
        app: paused
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      containers:
      - name: paused-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo 'Updated' && sleep 300"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/paused-deployment.yaml" -n "${KUASAR_TEST_NAMESPACE}"
	sleep 5

	# Resume the deployment
	kubectl rollout resume deployment/paused-deployment -n "${KUASAR_TEST_NAMESPACE}"
	kubectl rollout status deployment/paused-deployment -n "${KUASAR_TEST_NAMESPACE}" --timeout=120s

	# Verify update completed
	updated_pods=$(kubectl get pods -l app=paused -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
	[ -n "$updated_pods" ]
}

teardown() {
	kubectl delete deployments --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
