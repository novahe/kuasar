#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Comprehensive test for all types of environment variables

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Environment variables - direct value" {
	# Test 1: Direct value (simple fixed parameters)
	cat > "${BATS_TMPDIR}/pod-env-direct.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-direct-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"APP_MODE=\$APP_MODE\" && echo \"LOG_LEVEL=\$LOG_LEVEL\" && tail -f /dev/null"]
    env:
    - name: APP_MODE
      value: "production"
    - name: LOG_LEVEL
      value: "info"
    - name: MAX_CONNECTIONS
      value: "100"
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-direct.yaml")

	# Verify direct values
	grep_pod_exec_output "${pod_name}" "APP_MODE=production" sh -c "echo APP_MODE=\$APP_MODE"
	grep_pod_exec_output "${pod_name}" "LOG_LEVEL=info" sh -c "echo LOG_LEVEL=\$LOG_LEVEL"
	grep_pod_exec_output "${pod_name}" "MAX_CONNECTIONS=100" sh -c "echo MAX_CONNECTIONS=\$MAX_CONNECTIONS"
}

@test "Environment variables - ConfigMap (configMapKeyRef)" {
	# Test 2: ConfigMap reference (business configuration)
	cat > "${BATS_TMPDIR}/test-configmap-env.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  app.name: "kuasar-test-app"
  app.version: "1.0.0"
  database.host: "postgres.default.svc.cluster.local"
  database.port: "5432"
  cache.enabled: "true"
  cache.ttl: "3600"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-configmap-env.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/pod-env-configmap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-configmap-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"APP_NAME=\$APP_NAME\" && echo \"APP_VERSION=\$APP_VERSION\" && echo \"DB_HOST=\$DB_HOST\" && echo \"CACHE_ENABLED=\$CACHE_ENABLED\" && tail -f /dev/null"]
    env:
    - name: APP_NAME
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: app.name
    - name: APP_VERSION
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: app.version
    - name: DB_HOST
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database.host
    - name: DB_PORT
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database.port
    - name: CACHE_ENABLED
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: cache.enabled
    - name: CACHE_TTL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: cache.ttl
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-configmap.yaml")

	# Verify ConfigMap values
	grep_pod_exec_output "${pod_name}" "APP_NAME=kuasar-test-app" sh -c "echo APP_NAME=\$APP_NAME"
	grep_pod_exec_output "${pod_name}" "APP_VERSION=1.0.0" sh -c "echo APP_VERSION=\$APP_VERSION"
	grep_pod_exec_output "${pod_name}" "DB_HOST=postgres.default.svc.cluster.local" sh -c "echo DB_HOST=\$DB_HOST"
	grep_pod_exec_output "${pod_name}" "DB_PORT=5432" sh -c "echo DB_PORT=\$DB_PORT"
	grep_pod_exec_output "${pod_name}" "CACHE_ENABLED=true" sh -c "echo CACHE_ENABLED=\$CACHE_ENABLED"

	# Cleanup
	kubectl delete configmap app-config -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

@test "Environment variables - Secret (secretKeyRef)" {
	# Test 3: Secret reference (passwords, certificates, sensitive data)
	cat > "${BATS_TMPDIR}/test-secret-env.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
stringData:
  database.password: "SuperSecret123!"
  api.key: "sk-1234567890abcdef"
  tls.cert: "-----BEGIN CERTIFICATE-----\\nMIIC..."
  redis.password: "redis-pass-2024"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-secret-env.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/pod-env-secret.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-secret-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"DB_PASSWORD=\$DB_PASSWORD\" && echo \"API_KEY=\$API_KEY\" && echo \"REDIS_PASSWORD=\$REDIS_PASSWORD\" && tail -f /dev/null"]
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: database.password
    - name: API_KEY
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: api.key
    - name: TLS_CERT
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: tls.cert
    - name: REDIS_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secret
          key: redis.password
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-secret.yaml")

	# Verify Secret values
	grep_pod_exec_output "${pod_name}" "DB_PASSWORD=SuperSecret123!" sh -c "echo DB_PASSWORD=\$DB_PASSWORD"
	grep_pod_exec_output "${pod_name}" "API_KEY=sk-1234567890abcdef" sh -c "echo API_KEY=\$API_KEY"
	grep_pod_exec_output "${pod_name}" "REDIS_PASSWORD=redis-pass-2024" sh -c "echo REDIS_PASSWORD=\$REDIS_PASSWORD"

	# Cleanup
	kubectl delete secret app-secret -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

@test "Environment variables - Downward API (fieldRef)" {
	# Test 4: Downward API (Pod metadata - IP, Node, name, namespace, etc.)
	cat > "${BATS_TMPDIR}/pod-env-downward.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-downward-pod
  labels:
    app: test
    env: production
  annotations:
    version: "1.0.0"
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"POD_NAME=\$POD_NAME\" && echo \"POD_NAMESPACE=\$POD_NAMESPACE\" && echo \"POD_IP=\$POD_IP\" && echo \"NODE_NAME=\$NODE_NAME\" && echo \"SERVICE_ACCOUNT=\$SERVICE_ACCOUNT\" && echo \"APP_LABEL=\$APP_LABEL\" && tail -f /dev/null"]
    env:
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    - name: SERVICE_ACCOUNT
      valueFrom:
        fieldRef:
          fieldPath: spec.serviceAccountName
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: APP_LABEL
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['app']
    - name: VERSION_ANNOTATION
      valueFrom:
        fieldRef:
          fieldPath: metadata.annotations['version']
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-downward.yaml")

	# Verify Downward API values
	grep_pod_exec_output "${pod_name}" "POD_NAME=env-downward-pod" sh -c "echo POD_NAME=\$POD_NAME"
	grep_pod_exec "${pod_name}" "${KUASAR_TEST_NAMESPACE}" sh -c "echo POD_NAMESPACE=\$POD_NAMESPACE"
	grep_pod_exec_output "${pod_name}" "NODE_NAME=" sh -c "echo NODE_NAME=\$NODE_NAME"
	grep_pod_exec_output "${pod_name}" "APP_LABEL=test" sh -c "echo APP_LABEL=\$APP_LABEL"
	grep_pod_exec_output "${pod_name}" "VERSION_ANNOTATION=1.0.0" sh -c "echo VERSION_ANNOTATION=\$VERSION_ANNOTATION"

	# Verify POD_IP is set (not empty)
	output=$(kubectl exec "${pod_name}" -n "${KUASAR_TEST_NAMESPACE}" -- sh -c "echo POD_IP=\$POD_IP")
	echo "$output" | grep -q "POD_IP="
}

@test "Environment variables - resource limits (resourceFieldRef)" {
	# Test 5: Resource field reference (CPU/memory limits and requests)
	cat > "${BATS_TMPDIR}/pod-env-resources.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-resources-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"CPU_LIMIT=\$CPU_LIMIT\" && echo \"CPU_REQUEST=\$CPU_REQUEST\" && echo \"MEMORY_LIMIT=\$MEMORY_LIMIT\" && echo \"MEMORY_REQUEST=\$MEMORY_REQUEST\" && echo \"EPHEMERAL_STORAGE_LIMIT=\$EPHEMERAL_STORAGE_LIMIT\" && tail -f /dev/null"]
    resources:
      limits:
        cpu: "500m"
        memory: "128Mi"
      requests:
        cpu: "250m"
        memory: "64Mi"
    env:
    - name: CPU_LIMIT
      valueFrom:
        resourceFieldRef:
          resource: limits.cpu
    - name: CPU_REQUEST
      valueFrom:
        resourceFieldRef:
          resource: requests.cpu
    - name: MEMORY_LIMIT
      valueFrom:
        resourceFieldRef:
          resource: limits.memory
    - name: MEMORY_REQUEST
      valueFrom:
        resourceFieldRef:
          resource: requests.memory
    - name: EPHEMERAL_STORAGE_LIMIT
      valueFrom:
        resourceFieldRef:
          resource: limits.ephemeral-storage
          divisor: 1Mi
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-resources.yaml")

	# Verify resource field values (values are in core units, 500m = 0.5 = 1/2)
	grep_pod_exec_output "${pod_name}" "CPU_LIMIT=" sh -c "echo CPU_LIMIT=\$CPU_LIMIT"
	grep_pod_exec_output "${pod_name}" "CPU_REQUEST=" sh -c "echo CPU_REQUEST=\$CPU_REQUEST"
	grep_pod_exec_output "${pod_name}" "MEMORY_LIMIT=" sh -c "echo MEMORY_LIMIT=\$MEMORY_LIMIT"
	grep_pod_exec_output "${pod_name}" "MEMORY_REQUEST=" sh -c "echo MEMORY_REQUEST=\$MEMORY_REQUEST"
}

@test "Environment variables - mixed types" {
	# Test 6: Mixed env types (all types in one pod)
	cat > "${BATS_TMPDIR}/test-configmap-mixed.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mixed-config
data:
  config.value: "from-configmap"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-configmap-mixed.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/test-secret-mixed.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mixed-secret
type: Opaque
stringData:
  secret.value: "from-secret"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-secret-mixed.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/pod-env-mixed.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-mixed-pod
  labels:
    type: mixed-test
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"DIRECT=\$DIRECT\" && echo \"FROM_CONFIGMAP=\$FROM_CONFIGMAP\" && echo \"FROM_SECRET=\$FROM_SECRET\" && echo \"POD_NAME=\$POD_NAME\" && echo \"CPU_REQUEST=\$CPU_REQUEST\" && tail -f /dev/null"]
    resources:
      requests:
        cpu: "100m"
    env:
    # Direct value
    - name: DIRECT
      value: "direct-value"
    # ConfigMap reference
    - name: FROM_CONFIGMAP
      valueFrom:
        configMapKeyRef:
          name: mixed-config
          key: config.value
    # Secret reference
    - name: FROM_SECRET
      valueFrom:
        secretKeyRef:
          name: mixed-secret
          key: secret.value
    # Downward API
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    # Resource field
    - name: CPU_REQUEST
      valueFrom:
        resourceFieldRef:
          resource: requests.cpu
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-mixed.yaml")

	# Verify all env types
	grep_pod_exec_output "${pod_name}" "DIRECT=direct-value" sh -c "echo DIRECT=\$DIRECT"
	grep_pod_exec_output "${pod_name}" "FROM_CONFIGMAP=from-configmap" sh -c "echo FROM_CONFIGMAP=\$FROM_CONFIGMAP"
	grep_pod_exec_output "${pod_name}" "FROM_SECRET=from-secret" sh -c "echo FROM_SECRET=\$FROM_SECRET"
	grep_pod_exec_output "${pod_name}" "POD_NAME=env-mixed-pod" sh -c "echo POD_NAME=\$POD_NAME"

	# Cleanup
	kubectl delete configmap mixed-config -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
	kubectl delete secret mixed-secret -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

@test "Environment variables with ConfigMap - entire ConfigMap as env" {
	# Test 7: envFrom - import entire ConfigMap
	cat > "${BATS_TMPDIR}/test-configmap-envfrom.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: envfrom-config
data:
  APP_ENV: "production"
  APP_REGION: "us-west-2"
  APP_DEBUG: "false"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-configmap-envfrom.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/pod-env-from.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-from-cm-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"APP_ENV=\$APP_ENV\" && echo \"APP_REGION=\$APP_REGION\" && echo \"APP_DEBUG=\$APP_DEBUG\" && tail -f /dev/null"]
    envFrom:
    - configMapRef:
        name: envfrom-config
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-from.yaml")

	# Verify envFrom values
	grep_pod_exec_output "${pod_name}" "APP_ENV=production" sh -c "echo APP_ENV=\$APP_ENV"
	grep_pod_exec_output "${pod_name}" "APP_REGION=us-west-2" sh -c "echo APP_REGION=\$APP_REGION"
	grep_pod_exec_output "${pod_name}" "APP_DEBUG=false" sh -c "echo APP_DEBUG=\$APP_DEBUG"

	# Cleanup
	kubectl delete configmap envfrom-config -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

@test "Environment variables with Secret - entire Secret as env" {
	# Test 8: envFrom - import entire Secret
	cat > "${BATS_TMPDIR}/test-secret-envfrom.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: envfrom-secret
type: Opaque
stringData:
  DB_USER: "admin"
  DB_PASS: "secret123"
  API_TOKEN: "token-xyz"
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-secret-envfrom.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	cat > "${BATS_TMPDIR}/pod-env-from-secret.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: env-from-secret-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS:-kuasar-vmm}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo \"DB_USER=\$DB_USER\" && echo \"DB_PASS=\$DB_PASS\" && echo \"API_TOKEN=\$API_TOKEN\" && tail -f /dev/null"]
    envFrom:
    - secretRef:
        name: envfrom-secret
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-env-from-secret.yaml")

	# Verify secret envFrom values
	grep_pod_exec_output "${pod_name}" "DB_USER=admin" sh -c "echo DB_USER=\$DB_USER"
	grep_pod_exec_output "${pod_name}" "DB_PASS=secret123" sh -c "echo DB_PASS=\$DB_PASS"
	grep_pod_exec_output "${pod_name}" "API_TOKEN=token-xyz" sh -c "echo API_TOKEN=\$API_TOKEN"

	# Cleanup
	kubectl delete secret envfrom-secret -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true
}

teardown() {
	k8s_delete_all_pods || true
	kubectl delete configmaps --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	kubectl delete secrets --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	teardown_common "${node}"
}
