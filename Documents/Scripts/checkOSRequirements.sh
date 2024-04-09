#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

error_trap()
{
    if test -n "$1" ; then
        printf "%s\\n" "[ERROR] $1"
    fi

    printf "%.s=" $(seq 1 80)
    printf "\\nThe checkOSRequirements Script execution did not complete successfully.\\n"

    exit 1
}
compare_versions()
{
        # function to compare a program version with a supported one and throw an error if lower.
        program_ver="$1"
        supported_ver="$2"
        if [ "$(printf "%s\n" "${supported_ver}" "${program_ver}" | sort -V | head -n1)" = "${supported_ver}" ]; then
               echo "[INFO] OK - program version ${program_ver} greater than or equal to ${supported_ver}"
        else
               error_trap "FAIL - program version ${program_ver} less than ${supported_ver}"
        fi
}
unalias -a
shopt -s expand_aliases

# Check if aws cli is available in the outposts server instance
aws --version > /dev/null 2>&1 || error_trap "error in retrieving the aws cli version, please make sure aws cli is installed on the instance running on Outposts Server"

# Check if rsync is available in the outposts server instance and its version is equal or greater than the supported version
rsync --version > /dev/null 2>&1 || error_trap "error in retrieving the rsync version, please make sure rsync is installed on the instance running on Outposts Server"
RSYNC_SUPPORTED_VER="3.1.2"
RSYNC_SOURCE_VER=$(rsync --version | sed -n '1s/^rsync *version \([0-9.]*\).*$/\1/p')
echo "[INFO] Checking if rsync version is greater or equal to "${RSYNC_SUPPORTED_VER}""
compare_versions "${RSYNC_SOURCE_VER}" "${RSYNC_SUPPORTED_VER}"

# Check if sfdisk is available in the outposts server instance and its version is equal or greater than the supported version
sfdisk -v > /dev/null 2>&1 || error_trap "error in retrieving the sfdisk version, please make sure sfdisk is installed on the instance running on Outposts Server"
SFDISK_SUPPORTED_VER="2.26"
SFDISK_SOURCE_VER=$(sfdisk -v | awk 'NR==1' | sed 's/^.*[^0-9]\([0-9]*\.[0-9]*\.[0-9]*\).*$/\1/')
echo "[INFO] Checking if sfdisk version is greater or equal to "${SFDISK_SUPPORTED_VER}""
compare_versions "${SFDISK_SOURCE_VER}" "${SFDISK_SUPPORTED_VER}"

echo "[INFO] Execution finished successfully"
