#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test PID namespace

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Pod PID namespace" {
	pod_name=$(k8s_create_pod "${pod_config_dir}/busybox-pod.yaml")

	# Check PID 1 is the container process
	pid1_cmd=$(kubectl exec "${pod_name}" -- cat /proc/1/cmdline)
	[ -n "$pid1_cmd" ]

	# Check we can see processes in the pod
	pod_exec "${pod_name}" ps aux

	# Verify namespace isolation (should only see container processes)
	process_count=$(kubectl exec "${pod_name}" -- ps | wc -l)
	[ "$process_count" -lt 20 ]  # Should be much fewer than host processes
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
