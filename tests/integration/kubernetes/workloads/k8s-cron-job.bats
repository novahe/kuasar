#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test Kubernetes CronJob

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "CronJob creation" {
	# Create a CronJob
	cat > "${BATS_TMPDIR}/test-cronjob.yaml" <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: test-cronjob
spec:
  schedule: "* * * * *"
  jobTemplate:
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
          - name: cronjob-container
            image: ${BUSYBOX_IMAGE}
            command: ["sh", "-c", "echo CronJob ran at \$(date)"]
EOF

	kubectl apply -f "${BATS_TMPDIR}/test-cronjob.yaml" -n "${KUASAR_TEST_NAMESPACE}"

	# Wait a bit for the cronjob to be scheduled
	sleep 5

	# Check cronjob exists
	kubectl get cronjob test-cronjob -n "${KUASAR_TEST_NAMESPACE}"

	# Verify cronjob created successfully
	kubectl get cronjob test-cronjob -n "${KUASAR_TEST_NAMESPACE}" -o yaml | grep -q "schedule:.*\*.*\*.*\*.*\*.*\*"
}

teardown() {
	kubectl delete cronjobs --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	kubectl delete jobs --all -n "${KUASAR_TEST_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
