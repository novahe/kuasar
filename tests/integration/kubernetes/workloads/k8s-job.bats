#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Kubernetes Job

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Job completion" {
	# Create a Job
	cat > "${BATS_TMPDIR}/test-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: test-job
spec:
  template:
    metadata:
      labels:
        test-group: ${TEST_GROUP}
    spec:
      runtimeClassName: ${KUASAR_RUNTIME_CLASS}
      terminationGracePeriodSeconds: 0
      restartPolicy: Never
      containers:
      - name: job-container
        image: ${BUSYBOX_IMAGE}
        command: ["sh", "-c", "echo Job completed; exit 0"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-job.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait for job to complete
	kubectl wait --for=condition=complete --timeout=60s job/test-job -n "${KUASAR_TEST_NAMESPACE}"

	# Check job status
	kubectl get job test-job -n "${KUASAR_TEST_NAMESPACE}" -o yaml

	# Verify job completed successfully
	completed=$(kubectl get job test-job -n "${KUASAR_TEST_NAMESPACE}" -o jsonpath='{.status.succeeded}')
	[ "$completed" = "1" ]

	# Get pod logs from the job
	pod_name=$(kubectl get pods -l job-name=test-job -n "${KUASAR_TEST_NAMESPACE}" -o name | head -1 | sed 's/pod\///')
	if [ -n "$pod_name" ]; then
		logs=$(kubectl logs "$pod_name" -n "${KUASAR_TEST_NAMESPACE}")
		echo "$logs" | grep -q "Job completed"
	fi
}

teardown() {
	kubectl delete jobs --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
