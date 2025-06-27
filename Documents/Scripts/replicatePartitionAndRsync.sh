#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

error_trap()
{
    if test -n "$1" ; then
        printf "%s\\n" "[ERROR] $1"
    fi

    printf "%.s=" $(seq 1 80)
    printf "\\nThe BackupOutpostsServerInstance Script execution did not complete successfully.\\n"

    cleanup

    exit 1
}
cleanup()
{
        # remove the temporary path and its content
        rm -fr ${SCRIPT_PATH}
}
check_exclusions_for_partition()
{
       # function to check if the VALUE matches at least one of the regex in EXCLUSIONS_ARRAY.
       local VALUE="$1"
       shift
       local EXCLUSION_ARRAY=("$@")
       for EXCLUSION in "${EXCLUSION_ARRAY[@]}"
       do
               if [[ "${VALUE}" == "${EXCLUSION}" ]]; then
                       return 0
               fi
       done
       return 1
}
rsync_no_vanished()
{
        # function to prevent rsync resulting in error when files are deleted on the source while performing the backup. This is a normal scenarion in a Live System
        # Taken from rsync doc:  https://git.samba.org/?p=rsync.git;a=blob_plain;f=support/rsync-no-vanished;hb=HEAD

        REAL_RSYNC=/usr/bin/rsync
        IGNOREEXIT=24
        IGNOREOUT='^(file has vanished: |rsync warning: some files vanished before they could be transferred)'

        set -o pipefail

        # This filters stderr without merging it with stdout:
        { $REAL_RSYNC "${@}" 2>&1 1>&3 3>&- | grep -E -v "$IGNOREOUT"; ret=${PIPESTATUS[0]}; } 3>&1 1>&2

        if [[ $ret == $IGNOREEXIT ]]; then
                ret=0
        fi

        return $ret
}

unalias -a
shopt -s expand_aliases

UNIQUE_ID='{{ UniqueId }}'
AWS_REGION='{{ global:REGION }}'
HELPER_INSTANCE_PRIVATE_KEY_ID='{{ describeStackOutput.HelperInstanceKeyID }}'
HELPER_INSTANCE_PRIVATE_IP='{{ describeStackOutput.HelperInstancePrivateIp }}'
BASELINE_VOLUME_ID='{{ createBaselineVolume.BaselineVolumeId }}'
EXCLUSIONS_PARAMETER='{{ Exclusions }}'
BWLIMIT_PARAMETER='{{ MaxThroughput }}'

SCRIPT_PATH=/var/lib/amazon/ssm/BACKUP_AUTOMATION_${UNIQUE_ID}
HELPER_INSTANCE_PRIVATE_KEY_NAME=SSMAutomation-BackupOutpostsServerInstance-{{UniqueId}}-helperInstanceKey.pem

#Create Working Directory
mkdir ${SCRIPT_PATH} || error_trap "Failed to create the local path ${SCRIPT_PATH} to store the temporary script data"

# fetch the private key from the ssm parameters and store it in the .pem file
aws ssm get-parameter --region ${AWS_REGION} --name /ec2/keypair/${HELPER_INSTANCE_PRIVATE_KEY_ID} --with-decryption --query Parameter.Value --output text > "${SCRIPT_PATH}/${HELPER_INSTANCE_PRIVATE_KEY_NAME}" || error_trap "Failed to get the private key content and save it to a .pem file"
chmod 400 "${SCRIPT_PATH}/${HELPER_INSTANCE_PRIVATE_KEY_NAME}"

#Define the array of exclusions based on the user input and the Source Path
read -r -a EXCLUDES_ARRAY <<< "${EXCLUSIONS_PARAMETER}"

#Define the ssh user to access the Helper instance. The Helper instance is the latest AL2023 AMI, so the user is ec2-user
SSH_USER="ec2-user"
alias ssh_helper_instance="ssh -o StrictHostKeyChecking=no -i "${SCRIPT_PATH}/${HELPER_INSTANCE_PRIVATE_KEY_NAME}" ${SSH_USER}@${HELPER_INSTANCE_PRIVATE_IP}"

#Define the command alias to perform scp to the Helper instance
alias scp_helper_instance="scp -o StrictHostKeyChecking=no -i "${SCRIPT_PATH}/${HELPER_INSTANCE_PRIVATE_KEY_NAME}""

#Create Working Directory in the Helper instance
ssh_helper_instance "sudo mkdir ${SCRIPT_PATH}"
ssh_helper_instance "sudo chown ec2-user ${SCRIPT_PATH}"

#identify root device name and root device path
ROOT_DEVICE_NAME=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /))
ROOT_DEVICE_ABSOLUTE_PATH="/dev/${ROOT_DEVICE_NAME}"

echo "[INFO] Identified root device: ${ROOT_DEVICE_ABSOLUTE_PATH}"

#Backup the blocks storing the partition table data"
echo "[INFO] backing up the partition table of "${ROOT_DEVICE_ABSOLUTE_PATH}" of the source instance"
echo 'abort' | sfdisk -b --no-reread --backup-file "${SCRIPT_PATH}/sfdisk" ${ROOT_DEVICE_ABSOLUTE_PATH} > /dev/null 2>&1

#Copy the data to the Helper instance
echo "[INFO] copying the partition table backup to the Helper instance"
scp_helper_instance ${SCRIPT_PATH}/sfdisk-${ROOT_DEVICE_NAME}* ${SSH_USER}@${HELPER_INSTANCE_PRIVATE_IP}:${SCRIPT_PATH} || error_trap "Failed to copy the partition table backup from the source instance to the Helper instance"

#Retrieve the device path corresponding to the restored volume in the helper instance
ROOT_DEVICE_DISK_ID=$(sudo fdisk -l ${ROOT_DEVICE_ABSOLUTE_PATH} | awk '/Disk identifier/ {print $3}' ) || error_trap "Failed to determine the Root device ID of the source instance running on Outposts"
VOLUME_ID_DEV_DISK=$(echo ${BASELINE_VOLUME_ID} | tr -d '-')
TARGET_RESTORE_DEVICE_NAME=$(ssh_helper_instance "sudo basename \$(readlink /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID_DEV_DISK})") || error_trap "Failed to determine the device name of the target DEVICE (baseline volume)"
TARGET_RESTORE_DEVICE_ABSOLUTE_PATH="/dev/${TARGET_RESTORE_DEVICE_NAME}"

echo "[INFO] restoring the partition table backup to the volume "${TARGET_RESTORE_DEVICE_ABSOLUTE_PATH}" attached to the Helper instance"
for file_bak in ${SCRIPT_PATH}/sfdisk-${ROOT_DEVICE_NAME}-0x0*; do
        HEXADECIMAL_CODE=$(echo ${file_bak} | grep -o -E '0x[[:xdigit:]]+')
        ssh_helper_instance "sudo dd if=${file_bak} of=${TARGET_RESTORE_DEVICE_ABSOLUTE_PATH} seek=$((${HEXADECIMAL_CODE})) bs=1 conv=notrunc" || error_trap "Failed to restore the partition on the Restored volume in the Helper instance"
done

#Retrieve the list of partition names and their PARTUUID from the source device (instance store root volume)
SOURCE_PARTITIONS_LIST_PARTUUID=$(lsblk -nl -o NAME,TYPE,PARTUUID -e 7,11 "${ROOT_DEVICE_ABSOLUTE_PATH}" | awk '$2 == "part" {print $3 }') || error_trap "Failed to retrieve the lists of partitions PARTUUID on the Outposts server instance"

# iterate over the source partitions and perform the following checks and actions on each partition. Those checks and actions will be executed on the supported FS type only (xfs, ext4, vfat)
# 1) Check if the source and target partition are formatted with the same FS type. If different, format the target partition with the same FS of the source
# 2) Perform a FS check on the target FS. If it fails, format the target FS.
# 3) Check if the FS of the source and target partition have same UUID. If different, align the target FS with the same UUID of the source
# 4) Mount the target FS and check if the FS of the source and target partition have same size. Resize the target if different
# 5) Rsync the content of FS between the source and target

for source_partuuid in ${SOURCE_PARTITIONS_LIST_PARTUUID}; do
        SOURCE_PARTITION_FULL_PATH=$(blkid -t PARTUUID=$source_partuuid -o device) || error_trap "Failed to retrieve the source partition name from the PARTUUID"
        echo "================="
        echo "[INFO] Checking partition ${SOURCE_PARTITION_FULL_PATH} on the Outposts Server instance"

        #Retrieve the corresponding target partition using the PARTUUID (replicated from the partition table backup and restore)
        TARGET_PARTITION_FULL_PATH=$(ssh_helper_instance "sudo blkid --match-token PARTUUID=$source_partuuid -o device "${TARGET_RESTORE_DEVICE_ABSOLUTE_PATH}"*") || error_trap "Failed to retrieve the target partition name from the PARTUUID"
        echo "[INFO] Identified corresponding partition ${TARGET_PARTITION_FULL_PATH} on the Helper instance"

        # Check the FS of the source and target partition
        SOURCE_FS=$(lsblk -no FSTYPE ${SOURCE_PARTITION_FULL_PATH}) || error_trap "Failed to retrieve the Source FS type"
        echo "[INFO] source FS type is ${SOURCE_FS}"
        TARGET_FS=$(ssh_helper_instance "sudo lsblk -no FSTYPE ${TARGET_PARTITION_FULL_PATH}") || error_trap "Failed to retrieve the target FS type"
        echo "[INFO] target FS type is ${TARGET_FS}"

        echo "[INFO] checking if the partition ${SOURCE_PARTITION_FULL_PATH} is present in the Exclusions parameter. If excluded, skip to the next partition"
        check_exclusions_for_partition "${SOURCE_PARTITION_FULL_PATH}" "${EXCLUDES_ARRAY[@]}"
        value_excluded="$?"
        if [[ "${value_excluded}" -eq 0 ]]; then
               echo "[INFO] partition "${SOURCE_PARTITION_FULL_PATH}" excluded, no FS operations and data transfer will be performed. Skipping to the next partition"
               continue
        else
               echo "[INFO] partition ${SOURCE_PARTITION_FULL_PATH} not excluded. Proceeding with the next steps"
        fi

        case "${SOURCE_FS}" in
             "")
                     if [ -n "${TARGET_FS}" ]; then
                             echo "[INFO] partition with no FS on the source but with FS on the corresponding target partition, erasing the FS on target"
                             ssh_helper_instance "sudo wipefs --all ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to wipe fs on the target partition"
                     else
                             echo "[INFO] partition with no FS on both the source and the target, moving to the next step"
                     fi
                     ;;
             ext4|xfs|vfat)
                     if [ "${SOURCE_FS}" != "${TARGET_FS}" ]; then
                             echo "[INFO] wiping the ${TARGET_FS} on ${TARGET_PARTITION_FULL_PATH}"
                             ssh_helper_instance "sudo wipefs --all ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to wipe the ${TARGET_FS} on ${TARGET_PARTITION_FULL_PATH}"
                             echo "[INFO] Formatting ${TARGET_PARTITION_FULL_PATH} with ${SOURCE_FS}"
                             ssh_helper_instance "sudo mkfs.${SOURCE_FS} ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to format the partition ${TARGET_PARTITION_FULL_PATH} to ${SOURCE_FS}"
                     else
                             echo "[INFO] The Source and Target FS type match, nothing to do. Moving to the next step"
                     fi

                     # Perform a FS check on the target FS. If it fails, format the target FS.
                     echo "[INFO] performing a FS Check on the target ${TARGET_PARTITION_FULL_PATH}"
                     case "${SOURCE_FS}" in
                             ext4)
                                     ssh_helper_instance "sudo e2fsck -fy ${TARGET_PARTITION_FULL_PATH}"
                                     ;;
                             xfs)
                                     ssh_helper_instance "sudo xfs_repair ${TARGET_PARTITION_FULL_PATH}"
                                     ;;
                             vfat)
                                     ssh_helper_instance "sudo fsck.fat -a ${TARGET_PARTITION_FULL_PATH}"
                                     ;;
                             *)
                                     error_trap "Unsupported file system: ${SOURCE_FS}, stopping the execution. If you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
                     esac
                     if [ $? -ne 0 ]; then
                             echo "[INFO] File System check failed. Wiping and Formatting the target FS"
                             ssh_helper_instance "sudo wipefs --all ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to wipe the ${TARGET_FS} on ${TARGET_PARTITION_FULL_PATH}"
                             ssh_helper_instance "sudo mkfs.${SOURCE_FS} ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to format the partition ${TARGET_PARTITION_FULL_PATH} to ${SOURCE_FS}"
                     else
                             echo "[INFO] File System Check on the target was successful. Moving to the next step"
                     fi

                     # Get the UUID and LABEL of the FS of the source and target partition
                     SOURCE_UUID=$(blkid -s UUID -o value ${SOURCE_PARTITION_FULL_PATH}) || error_trap "Failed to retrieve the UUID of the source FS"
                     TARGET_UUID=$(ssh_helper_instance "sudo blkid -s UUID -o value ${TARGET_PARTITION_FULL_PATH}") || error_trap "Failed to retrieve the UUID of the target FS"
                     SOURCE_LABEL=$(blkid -s LABEL -o value ${SOURCE_PARTITION_FULL_PATH}) || error_trap "Failed to retrieve the LABEL of the source FS"
                     TARGET_LABEL=$(ssh_helper_instance "sudo blkid -s LABEL -o value ${TARGET_PARTITION_FULL_PATH}") || error_trap "Failed to retrieve the LABEL of the target FS"
                     # Check and label the target file system with the same UUID as the source file system
                     if [ "${SOURCE_UUID}" != "${TARGET_UUID}" ]; then
                             echo "[INFO] setting the UUID of the FS ${SOURCE_FS} on ${TARGET_PARTITION_FULL_PATH} to ${SOURCE_UUID}"
                             case "${SOURCE_FS}" in
                                     ext4)
                                             ssh_helper_instance "sudo tune2fs ${TARGET_PARTITION_FULL_PATH} -U ${SOURCE_UUID}" || error_trap "Failed to set the UUID ${SOURCE_UUID} on the target FS"
                                             ;;
                                     xfs)
                                             ssh_helper_instance "sudo xfs_admin -U ${SOURCE_UUID} ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to set the UUID ${SOURCE_UUID} on the target FS"
                                             ;;
                                     vfat)
                                             ssh_helper_instance "sudo mkfs.vfat -i "${SOURCE_UUID//-}" ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to set the UUID ${SOURCE_UUID} on the target FS"
                                             ;;
                                     *)
                                             error_trap "Unsupported file system: ${SOURCE_FS}, stopping the execution. If you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
                             esac
                     else
                             echo "[INFO] The Source and Target FS UUID match, nothing to do. Moving to the next step"
                     fi

                     # Check and label the target file system with the same LABEL as the source file system
                     if [ -n "${SOURCE_LABEL}" ]; then
                             if [ "${SOURCE_LABEL}" != "${TARGET_LABEL}" ]; then
                                     echo "[INFO] Labeling ${TARGET_PARTITION_FULL_PATH} with ${SOURCE_LABEL}"
                                     case "${SOURCE_FS}" in
                                             ext4)
                                                     ssh_helper_instance "sudo e2label ${TARGET_PARTITION_FULL_PATH} ${SOURCE_LABEL}" || error_trap "Failed to label the target FS"
                                                     ;;
                                             xfs)
                                                     ssh_helper_instance "sudo xfs_admin -L ${SOURCE_LABEL} ${TARGET_PARTITION_FULL_PATH}" || error_trap "Failed to label the target FS"
                                                     ;;
                                             vfat)
                                                     ssh_helper_instance "sudo fatlabel ${TARGET_PARTITION_FULL_PATH} ${SOURCE_LABEL}" || error_trap "Failed to label the target FS"
                                                     ;;
                                             *)
                                                     error_trap "Unsupported file system: ${SOURCE_FS}, stopping the execution. If you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
                                     esac
                             else
                                     echo "[INFO] The Source and Target FS LABEL match, nothing to do. Moving to the next step"
                             fi
                     else
                             echo "[INFO] No LABEL on the source FS. Moving to the next step"
                     fi
                     #Get the source FS mountpoint for the partition and retrieve the FS size
                     SOURCE_FS_MOUNTPOINT=$(findmnt -o TARGET "${SOURCE_PARTITION_FULL_PATH}" | sed "1 d") || error_trap "Failed to get source FS Mountpoint"
                     SOURCE_FS_SIZE=$(df -k "${SOURCE_FS_MOUNTPOINT}" | awk 'NR==2 {print $2}') ||  error_trap "Failed to get source FS size"

                     if [ -n "${SOURCE_FS_SIZE}" ]; then
                             #Mount the target file system
                             BASE_MOUNT="/mnt"
                             MOUNT_DIR="${BASE_MOUNT}${SOURCE_FS_MOUNTPOINT}"
                             ssh_helper_instance "sudo mkdir -p ${MOUNT_DIR}" || error_trap "Failed to create the mount point directory ${MOUNT_DIR} on the helper instance"
                             echo "[INFO] Mounting ${TARGET_PARTITION_FULL_PATH} to ${MOUNT_DIR}"
                             if [ "${SOURCE_FS}" == "xfs" ]; then
                                     ssh_helper_instance "sudo mount -o nouuid ${TARGET_PARTITION_FULL_PATH} ${MOUNT_DIR}" ||  error_trap "Failed to mount the target FS on ${TARGET_PARTITION_FULL_PATH}"
                             else
                                     ssh_helper_instance "sudo mount ${TARGET_PARTITION_FULL_PATH} ${MOUNT_DIR}" ||  error_trap "Failed to mount the target FS on ${TARGET_PARTITION_FULL_PATH}"
                             fi

                             #Check and resize the target file system to match the source file system size
                             echo "[INFO] Size (1K) of the Source FS on ${SOURCE_PARTITION_FULL_PATH}: ${SOURCE_FS_SIZE}"
                             TARGET_FS_SIZE=$(ssh_helper_instance "sudo df -k ${MOUNT_DIR} | awk 'NR==2 {print \$2}'") || error_trap "Failed to get target FS size"
                             echo "[INFO] Size (1K) of the Target FS on ${TARGET_PARTITION_FULL_PATH}: ${TARGET_FS_SIZE}"

                             if [ "${SOURCE_FS_SIZE}" != "${TARGET_FS_SIZE}" ]; then
                                     echo "[INFO] Resizing ${TARGET_PARTITION_FULL_PATH} to match the source file system size"
                                     case "${SOURCE_FS}" in
                                             ext4)
                                                     SOURCE_EXT_FS_BLOCKS=$(dumpe2fs -h ${SOURCE_PARTITION_FULL_PATH} | awk -F: '/Block count/{count=$2} END{print count}' | tr -d " \t\r") || error_trap "Failed to get the number of blocks of the source ext FS"
                                                     ssh_helper_instance "sudo resize2fs ${TARGET_PARTITION_FULL_PATH} ${SOURCE_EXT_FS_BLOCKS}" || error_trap "Failed to resize the target FS"
                                                     ;;
                                             xfs)
                                                     SOURCE_XFS_FS_BLOCKS=$(xfs_info ${SOURCE_FS_MOUNTPOINT} | grep -e "^data" | grep -oP 'blocks=\K[^ ,]+' | cut -d "=" -f2) || error_trap "Failed to get the number of blocks of the source xfs FS"
                                                     ssh_helper_instance "sudo xfs_growfs ${MOUNT_DIR} -D ${SOURCE_XFS_FS_BLOCKS}" || error_trap "Failed to resize the target FS"
                                                     ;;
                                             *)
                                                     error_trap "Unsupported file system: ${SOURCE_FS}, stopping the execution. If you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
                                     esac
                             else
                                     echo "[INFO] The Source and Target FS size match, nothing to do. Moving to the next step"
                             fi

                             # Set base rsync options
                             RSYNC_OPTIONS=(--stats --delete -avHAxXSPRz)

                             # Add specific options for vfat filesystem
                             [[ "${SOURCE_FS}" == "vfat" ]] && RSYNC_OPTIONS+=( --filter='-x security.selinux')

                             # Build bwlimit parameter if needed
                             BWLIMIT_FLAG=()
                             [[ ${BWLIMIT_PARAMETER} -gt 0 ]] && BWLIMIT_FLAG=(--bwlimit=${BWLIMIT_PARAMETER})

                             echo "[INFO] executing rsync of the content between the source and target FS"
                             rsync_no_vanished -e "ssh -o StrictHostKeyChecking=no -i "${SCRIPT_PATH}/${HELPER_INSTANCE_PRIVATE_KEY_NAME}"" --rsync-path="sudo rsync" "${EXCLUDES_ARRAY[@]/#/--exclude=}" --exclude="${SCRIPT_PATH}" "${BWLIMIT_FLAG[@]}" "${RSYNC_OPTIONS[@]}" "${SOURCE_FS_MOUNTPOINT}/" ${SSH_USER}@${HELPER_INSTANCE_PRIVATE_IP}:${BASE_MOUNT} || error_trap "Failed to rsync the content between the Source and target FS"

                             echo "[INFO] rsync completed!"

                             echo "[INFO] unmounting ${TARGET_PARTITION_FULL_PATH}"
                             #unmounting the target file system
                             ssh_helper_instance "sudo umount ${TARGET_PARTITION_FULL_PATH}" ||  error_trap "Failed to unmount the target FS on ${TARGET_PARTITION_FULL_PATH}"

                     else
                             echo "[INFO] The FS is not mounted on the Source. Cannot replicate the data. Moving to the next step"
                     fi
                     ;;
             *LVM2_member*)
                     error_trap "The partition "${SOURCE_PARTITION_FULL_PATH}" on Outposts Server instance is managed by LVM. LVM is not Supported on this Automation. We suggest using the native snapshotting capabilities provided by LVM to backup your data and save the snapshots on durable storage (e.g. S3, EBS). you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
                     ;;
             *)
                     error_trap "Unsupported file system: ${SOURCE_FS}, stopping the execution. If you want to skip this partition and perform the backup operations on the other ones, you can add ${SOURCE_PARTITION_FULL_PATH} to the Exclusions"
        esac

done
echo "================="
echo "[INFO] Execution finished successfully"
cleanup || error_trap "Failed to cleanup the temporary script data"
