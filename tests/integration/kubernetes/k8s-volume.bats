#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test volume mounting

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "EmptyDir volume" {
	# Create pod with emptyDir volume
	cat > "${BATS_TMPDIR}/pod-volume.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: volume-test-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'test data' > /cache/test.txt && cat /cache/test.txt && tail -f /dev/null"]
    volumeMounts:
    - name: cache-volume
      mountPath: /cache
  volumes:
  - name: cache-volume
    emptyDir: {}
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-volume.yaml")

	# Verify volume is working
	grep_pod_exec_output "${pod_name}" "test data" cat /cache/test.txt
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
