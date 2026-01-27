#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test kubectl exec functionality

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "kubectl exec to pod" {
	pod_name=$(k8s_create_pod "${pod_config_dir}/busybox-pod.yaml")

	# Test basic exec
	pod_exec "${pod_name}" echo "Hello from pod"

	# Test exec with output
	output=$(pod_exec "${pod_name}" echo "test output")
	[ "$output" = "test output" ]

	# Test exec with different commands
	pod_exec "${pod_name}" ls /
	pod_exec "${pod_name}" cat /proc/1/cmdline
	pod_exec "${pod_name}" uname -a
}

@test "kubectl exec with multiple commands" {
	pod_name=$(k8s_create_pod "${pod_config_dir}/busybox-pod.yaml")

	# Test command chaining
	output=$(pod_exec "${pod_name}" sh -c "echo hello && echo world")
	echo "$output" | grep -q "hello"
	echo "$output" | grep -q "world"

	# Test redirection
	pod_exec "${pod_name}" sh -c "echo test > /tmp/test.txt && cat /tmp/test.txt"
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
