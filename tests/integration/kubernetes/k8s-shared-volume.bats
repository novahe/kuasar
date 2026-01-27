#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test shared volume between containers

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Shared volume between containers" {
	# Create pod with shared volume
	cat > "${BATS_TMPDIR}/pod-shared-volume.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: shared-volume-pod
spec:
  runtimeClassName: ${KUASAR_RUNTIME_CLASS}
  containers:
  - name: writer
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "echo 'shared data' > /data/shared.txt && tail -f /dev/null"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  - name: reader
    image: ${BUSYBOX_IMAGE}
    command: ["sh", "-c", "sleep 5 && cat /data/shared.txt && tail -f /dev/null"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  volumes:
  - name: shared-data
    emptyDir: {}
EOF

	pod_name=$(k8s_create_pod "${BATS_TMPDIR}/pod-shared-volume.yaml")

	# Verify both containers can access the shared data
	output=$(kubectl exec "${pod_name}" -c reader -- cat /data/shared.txt)
	[ "$output" = "shared data" ]
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
