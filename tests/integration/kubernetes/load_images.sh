#!/usr/bin/env bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Load image configuration

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source image configuration
if [ -f "${script_dir}/images.conf" ]; then
	source "${script_dir}/images.conf"
else
	echo "WARNING: images.conf not found, using defaults"
	BUSYBOX_IMAGE=${BUSYBOX_IMAGE:-quay.io/prometheus/busybox:latest}
	NGINX_IMAGE=${NGINX_IMAGE:-nginx:alpine}
	AGHOST_IMAGE=${AGHOST_IMAGE:-registry.k8s.io/e2e-test-images/agnhost:2.21}
fi

# Export images for use in templates and envsubst
export BUSYBOX_IMAGE
export NGINX_IMAGE
export AGHOST_IMAGE
export TEST_IMAGE_1
export TEST_IMAGE_2

# Display loaded images (for debugging)
if [ "${DEBUG_IMAGES:-false}" = "true" ]; then
	echo "Loaded images:"
	echo "  BUSYBOX_IMAGE=${BUSYBOX_IMAGE}"
	echo "  NGINX_IMAGE=${NGINX_IMAGE}"
	echo "  AGHOST_IMAGE=${AGHOST_IMAGE}"
fi
