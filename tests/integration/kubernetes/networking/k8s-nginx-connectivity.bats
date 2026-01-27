#!/usr/bin/env bats
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Test nginx pod connectivity

load "${BATS_TEST_DIRNAME}/../lib.sh"
load "${BATS_TEST_DIRNAME}/../common.bash"

setup() {
	setup_common || die "setup_common failed"
}

@test "Nginx pod connectivity" {
	pod_name=$(k8s_create_pod "${pod_config_dir}/nginx-pod.yaml")

	# Check pod is running
	is_pod_running "${pod_name}"

	# Test connectivity within the pod
	# Wait for nginx to start
	sleep 5

	# Test localhost connectivity
	pod_exec "${pod_name}" wget -O - http://localhost

	# Test with curl if available
	pod_exec "${pod_name}" sh -c 'which curl && curl http://localhost || true'
}

teardown() {
	k8s_delete_all_pods || true
	teardown_common "${node}"
}
