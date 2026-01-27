#!/usr/bin/env bash
#
# Copyright (c) 2026 The Kuasar Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Process YAML template files to replace image variables

# This script is called by setup.sh to replace ${BUSYBOX_IMAGE}, ${NGINX_IMAGE}, etc.
# in YAML files with actual image values

yaml_file="$1"

if [ ! -f "$yaml_file" ]; then
	exit 0
fi

# Export image variables for envsubst
export BUSYBOX_IMAGE NGINX_IMAGE AGHOST_IMAGE TEST_IMAGE_1 TEST_IMAGE_2

# Use envsubst to replace variables in the YAML file
# This will replace ${BUSYBOX_IMAGE}, ${NGINX_IMAGE}, etc. with their values
envsubst < "$yaml_file" > "${yaml_file}.tmp"
mv "${yaml_file}.tmp" "$yaml_file"
