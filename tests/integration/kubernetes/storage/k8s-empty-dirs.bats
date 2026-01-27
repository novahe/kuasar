#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test multiple emptyDir volumes

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Multiple emptyDir volumes" {
	# Create pod with multiple emptyDir volumes
	cat > "${BATS_TMPDIR}/pod-multi-emptydirs.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multi-emptydirs-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: test-container
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'data1' > /cache1/file1.txt && echo 'data2' > /cache2/file2.txt && tail -f /dev/null"]
    volumeMounts:
    - name: cache-volume-1
      mountPath: /cache1
    - name: cache-volume-2
      mountPath: /cache2
  volumes:
  - name: cache-volume-1
    emptyDir: {}
  - name: cache-volume-2
    emptyDir: {}
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-multi-emptydirs.yaml")

	# Verify both volumes are working
	grep_pod_exec_output "${pod_name}" "data1" cat /cache1/file1.txt
	grep_pod_exec_output "${pod_name}" "data2" cat /cache2/file2.txt
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
