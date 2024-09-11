#!/bin/bash

#######################################################################
# Purpose: This script is used to reassign the Network Interface Card (NIC)
#          from the Windows ZCA VM to the Linux ZCA VM and the NIC from the Linux ZCA VM to the Windows ZCA VM within an AWS environment.
#          Once the script is completed, the Linux ZCA VM will be recreated with the Windows ZCA VM's NIC (IP address), 
#          and the Windows ZCA VM will be recreated with the Linux ZCA VM's NIC (IP address).
#
# Prerequisites: This script assumes you have the required permissions and access rights
#                to manage virtual machines and network resources within your AWS account.
#                The source Windows ZCA and target Linux ZCA machines will be recreated.
#
# Steps:
#       1. Backup both Windows ZCA VM and Linux ZCA by creating an AMI (Create image).
#       Those AMIs should be saved Utill the whole migration process is finished successfully and verified.

#       2. Upload the script to AWS CloudShell.
# 
#       3. Run the following command: - chmod +x [script name]
#       e.g.: chmod +x reassign-nic.bash
#       This enables permissions to run the script.
# 
#       4. To execute the script run the following command: 
#       - ./reassign-nic.bash --windows-zca-ip [ip] --linux-zca-ip [ip]
#       e.g.: ./reassign-nic.bash --windows-zca-ip 127.10.10.10 --linux-zca-ip 127.10.10.11
# 
#       5. If reassign failed after terminating the instances, execute the script again with the "recreate" argument:
#       - ./reassign-nic.bash --windows-zca-ip [ip] --linux-zca-ip [ip] --recreate [recreation-params file path]
#       e.g.: ./reassign-nic.bash --windows-zca-ip 127.10.10.10 --linux-zca-ip 127.10.10.11 --recreate recreation-params-20240415164057.txt
#
#       Throughout the procedure, a log file is generated in close proximity to the script's running location, capturing details about the execution of the script.
#       The log file will be created at the location of the script.
#######################################################################

# Set errexit option to stop processing when any command fails
set -e

start_script_timestamp=$(date +%Y%m%d%H%M%S)

#Set output and logging
log_file="zca-migration-output-${start_script_timestamp}.log"
exec 3>>"$log_file"

# Redirect all output to both console and log file
exec > >(tee -a /dev/fd/3) 2>&1

#Set recreate instance params file
recreation_params_file="recreation-params-${start_script_timestamp}.txt"

#OS types
windows_os="Windows"
linux_os="Linux"

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
NORMAL=$(tput sgr0)

logDebug () {
    timestamp=$(date +%Y%m%d%H%M%S)
    if [[ $__VERBOSE -eq 1 ]]; then
        echo "$timestamp, $@"
    else
        echo "$timestamp, $@" >&3
    fi
}

logInfo () {
  timestamp=$(date +%Y%m%d%H%M%S)
  echo "$timestamp, $@"
}

logDotToOutputWithoutNewLine () {
  echo -n "*" > /dev/tty
}

logNewLineToOutput () {
  echo "*" > /dev/tty
}

logError () {
  timestamp=$(date +%Y%m%d%H%M%S)
  echo "$timestamp, ${RED}$@${NORMAL}" >&2
}

logToFileOnly () {
  timestamp=$(date +%Y%m%d%H%M%S)
  echo "$timestamp, $@" >&3
}

getInstanceFilteredAwsTags () {
  local instance="$1"
  local original_tags=$(jq -c '.Reservations[].Instances[].Tags[]?' <<< "$instance")
  local tags=$(addPrefixToAwsTags "$original_tags")
  echo "$tags"
}

addPrefixToAwsTags () {
  local tags="$1"
  
  local modified_tags=$(jq -c '
    if .Key | test("^aws:"; "i") then 
      .Key = "ZERTO:" + .Key
    else 
      . 
    end' <<< "$tags")

  local modified_tags_line=$(echo "$modified_tags" | tr -d '\n')

  echo "$modified_tags_line"
}

fetchVolumeMetadata() {
    local zca_instance="$1"
    local volumes_info="$2"
    local zca_volumes=""

    # Iterate over each volume
    while IFS= read -r volume; do
        local device_name=$(jq -r '.DeviceName' <<< "$volume")
        local virtual_name=$(jq -r '.VirtualName' <<< "$volume")
        # Check if "Ebs" property exists
        if jq -e '.Ebs' <<< "$volume" >/dev/null; then
            local ebs=$(jq -r '.Ebs' <<< "$volume")
            local delete_on_termination=$(jq -r '.DeleteOnTermination // false' <<< "$ebs")

            # Retrieve additional metadata for the volume
            local volume_id=$(jq -r '.VolumeId' <<< "$ebs")
            local volume_details=$(jq -r '.Volumes[] | select(.VolumeId == "'"$volume_id"'")' <<< "$volumes_info")
            local encrypted=$(jq -r '.Encrypted // empty' <<< "$volume_details")
            local kms_key_id=$(jq -r '.KmsKeyId // empty' <<< "$volume_details")
            local volume_type=$(jq -r '.VolumeType // empty' <<< "$volume_details")
            local iops=$(jq -r '.Iops // empty' <<< "$volume_details")
            local throughput=$(jq -r '.Throughput // empty' <<< "$volume_details")

            # Construct JSON object for the Ebs property
            local ebs_json="\"Ebs\":{"
            if [ -n "$delete_on_termination" ]; then
                ebs_json+="\"DeleteOnTermination\":$delete_on_termination,"
            fi
            if [ -n "$encrypted" ]; then
                ebs_json+="\"Encrypted\":$encrypted,"
            fi
            if [ -n "$kms_key_id" ]; then
                ebs_json+="\"KmsKeyId\":\"$kms_key_id\","
            fi
            if [ -n "$volume_type" ]; then
                ebs_json+="\"VolumeType\":\"$volume_type\","
            fi
            if [ -n "$iops" ] && ([ "$volume_type" == "io1" ] || [ "$volume_type" == "io2" ]); then
                ebs_json+="\"Iops\":$iops,"
            fi
            if [ -n "$throughput" ] && ([ "$volume_type" == "sc1" ] || [ "$volume_type" == "st1" ]); then
                ebs_json+="\"Throughput\":$throughput,"
            fi
            # Remove the trailing comma
            ebs_json="${ebs_json%,}"
            ebs_json+="}"
        else
            # Set default values if "Ebs" property does not exist
            local ebs_json="\"Ebs\":{\"DeleteOnTermination\":false}"
        fi

        # Construct JSON object for the volume
        local volume_json="{\"DeviceName\":\"$device_name\""
        if [ -n "$virtual_name" ] && [ "$virtual_name" != "null" ] && [ "$virtual_name" != "" ]; then
            volume_json+=",\"VirtualName\":\"$virtual_name\""
        fi
        if [ -n "$ebs_json" ]; then
            volume_json+=",$ebs_json"
        fi
        volume_json+="}"

        # Append volume JSON to the string
        zca_volumes="$zca_volumes$volume_json,"
    done < <(jq -c '.Reservations[].Instances[].BlockDeviceMappings[]?' <<< "$zca_instance")

    # Remove the trailing comma
    zca_volumes="${zca_volumes%,}"

    # Return the volumes metadata
    echo "$zca_volumes"
}

fetchVolumesTags() {
    local volumes_info="$1"
    local zca_volumes_tags="{\"Volumes\": []}"  # Start with an empty array

    while IFS= read -r volume; do
        local device_name=$(jq -r '.Attachments[0].Device' <<< "$volume")
        
        # Check if Tags array exists and is not null
        if jq -e '.Tags // empty | length > 0' <<< "$volume" >/dev/null; then
            local original_tags=$(jq -c '.Tags' <<< "$volume")
            local tags=$(addPrefixToAwsTags $(jq -c '.[]' <<< "$original_tags"))

            # Append new object to the array
            zca_volumes_tags=$(jq --arg device_name "$device_name" --argjson tags "${tags[@]}" \
                '.Volumes += [{DeviceName: $device_name, Tags: $tags}]' <<< "$zca_volumes_tags")
        fi
    done < <(jq -c '.Volumes[]' <<< "$volumes_info")

    zca_volumes_tags=$(tr -d '\n' <<< "$zca_volumes_tags")
    echo "$zca_volumes_tags"
}

fetchPlacementInfo() {
    local zca_instance="$1"
    local placement_info=""

    # Extract individual elements from placement data
    local availability_zone=$(jq -r '.Reservations[].Instances[].Placement.AvailabilityZone // empty' <<< "$zca_instance")
    local group_name=$(jq -r '.Reservations[].Instances[].Placement.GroupName // empty' <<< "$zca_instance")
    local partition_number=$(jq -r '.Reservations[].Instances[].Placement.PartitionNumber // empty' <<< "$zca_instance")
    local tenancy=$(jq -r '.Reservations[].Instances[].Placement.Tenancy // empty' <<< "$zca_instance")
    local group_id=$(jq -r '.Reservations[].Instances[].Placement.GroupId // empty' <<< "$zca_instance")

    # Append non-empty properties to placement_info
    [ -n "$availability_zone" ] && placement_info+="AvailabilityZone=$availability_zone,"
    [ -n "$group_id" ] && placement_info+="GroupId=$group_id,"
    # Add group_name only in case group_id is empty or null
    [ -z "$group_id" ] && [ -n "$group_name" ] && placement_info+="GroupName=$group_name,"
    [ -n "$partition_number" ] && placement_info+="PartitionNumber=$partition_number,"
    [ -n "$tenancy" ] && placement_info+="Tenancy=$tenancy"

    # Remove trailing comma
    placement_info=$(echo "$placement_info" | sed 's/,$//')

    echo "$placement_info"
}

printInstanceProperties () {
  local instance_os="$1"
  local zca_instance_id="$2"
  local nic_id="$3"
  local nic_attachmentId="$4"
  local original_delete_on_termination_for_nic="$5"
  local zca_iam_role_arn="$6"
  local zca_instance_type="$7"
  local zca_instance_key_pair="$8"
  local zca_disable_api_termination="$9"
  local zca_initiated_shutdown_behavior="${10}"
  local zca_disable_api_disable_api_stop="${11}"
  local zca_capacity_reservation="${12}"
  local zca_placement_group="${13}"
  shift 13  # Shift past the first X parameters
  local volumes=("${1}") 
  local zca_volumes_tags="${2}" 
  shift 2  # Shift past the next two parameters
  local tags=("$@")  # Store remaining parameters in an array

  tags_string=$(jq -r '"{Key=\"\(.Key)\",Value=\"\(.Value)\"},"' <<< "${tags[@]}")
  # Remove the trailing comma
  if [ -n "$tags_string" ]; then
      tags_string="${tags_string%,}"
  fi
  
  logDebug "ZCA $instance_os: zca_instance_id: ${GREEN}$zca_instance_id${NORMAL} \
            nic_id: $nic_id \
            nic_attachmentId: $nic_attachmentId \
            original_delete_on_termination_for_nic: $original_delete_on_termination_for_nic \
            zca_iam_role_arn: $zca_iam_role_arn \
            zca_instance_type: $zca_instance_type \
            zca_instance_key_pair: $zca_instance_key_pair \
            zca_disable_api_termination: $zca_disable_api_termination \
            zca_initiated_shutdown_behavior: $zca_initiated_shutdown_behavior \
            zca_disable_api_disable_api_stop: $zca_disable_api_disable_api_stop \
            zca_capacity_reservation: $zca_capacity_reservation \
            zca_placement_group: $zca_placement_group \
            instance tags: $tags_string \
            instance volumes: $volumes \
            volumes tags: $zca_volumes_tags"
}

setDeleteOnTerminationForNic () {
  local instance_os="$1"
  local nic_id="$2"
  local nic_attachmentId="$3"
  local should_delete_on_termination="$4"
  local current_should_delete_on_termination="$5"

  # Check if the desired delete on termination status matches the current status
  if [ "$should_delete_on_termination" = "$current_should_delete_on_termination" ]; then
    logDebug "$instance_os ZCA NIC ID: $nic_id and NIC AttachmentId $nic_attachmentId is already as desired: $should_delete_on_termination. No action is needed."
    return
  fi

  modify_network_interface_command="aws ec2 modify-network-interface-attribute --network-interface-id \"$nic_id\" --attachment \"AttachmentId=$nic_attachmentId,DeleteOnTermination=$should_delete_on_termination\""
  logToFileOnly "About to run the command: $modify_network_interface_command"
  if ! eval "$modify_network_interface_command"; then
    logError "Failed to set DeleteOnTermination for $instance_os ZCA NIC ID: $nic_id and NIC AttachmentId $nic_attachmentId"
    return 1
  fi
  
  logInfo "${GREEN}$instance_os ZCA NIC ID: $nic_id and NIC AttachmentId $nic_attachmentId set to DeleteOnTermination: $should_delete_on_termination.${NORMAL}"
}

setAttributeForInstanceIfNeeded () {
  local instance_os="$1"
  local zca_instance_id="$2"
  local attribute="$3"
  local attribute_value="$4"
  local current_attribute_value="$5"
  local is_boolean_value="$6"

  # Check if the desired termination protection status matches the current status
  if [ "$attribute_value" = "$current_attribute_value" ]; then
    logDebug "$instance_os ZCA $attribute attribute for instance $zca_instance_id is already as desired: $attribute_value. No action is needed."
    return
  fi

  if [ "$is_boolean_value" = true ]; then
    if [ "$attribute_value" = false ]; then
      attribute="no-$attribute"
    fi
    set_attribute_command="aws ec2 modify-instance-attribute --instance-id \"$zca_instance_id\" --$attribute"

  else
    set_attribute_command="aws ec2 modify-instance-attribute --instance-id \"$zca_instance_id\" --$attribute \"$attribute_value\""
  fi

  logToFileOnly "About to run the command: $set_attribute_command"

  if ! eval "$set_attribute_command"; then
    logError "Failed to set ModifyInstanceAttribute for $instance_os ZCA attribute $attribute value $attribute_value"
    return 1
  fi

  logInfo "${GREEN}$instance_os ZCA ID: $zca_instance_id attribute: $attribute set to: $attribute_value.${NORMAL}"
}

stopInstanceAsync () {
  local instance_id="$1"

  if ! aws ec2 stop-instances --instance-ids "$instance_id"; then
    logError "Failed to stop instance $instance_id"
    return 1
  fi
}

startInstanceAsync () {
  local instance_id="$1"

  #Allow a grace period in case the shutdown fails, giving the VM time to recover before attempting to start it up again
  sleep 120
  
  if ! aws ec2 start-instances --instance-ids "$instance_id"; then
    logError "Failed to start instance $instance_id"
    return 1
  fi
}

waitTillInstanceStopped () {
  local os_type="$1"
  local instance_id="$2"

  # Timeout in seconds
  timeout=300
  start_time=$SECONDS
  # Wait for the instance to reach the "stopped" state
  while true; do
      instance_state=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[].Instances[].State.Name' --output text)

      if [ "$instance_state" = "stopped" ]; then
        logNewLineToOutput
        logInfo "${GREEN}$os_type ZCA VM  $instance_id has been stopped successfully.${NORMAL}"
        break
      elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
        logNewLineToOutput
        logError "Timeout reached while waiting for instance $instance_id to stop."
        return 1
      else
        logDebug "Waiting for the instance $instance_id to stop. Current state: $instance_state..."
        logDotToOutputWithoutNewLine
        sleep 5
      fi
  done
}

createAmiAsync () {
  local instance_id="$1"
  local instance_name="$2"
  local windowsZcaIp="$3"
  local linuxZcaIp="$4"

  timestamp=$(date +%Y%m%d%H%M%S)

  # Create instance command string
  createAmiCommand="aws ec2 create-image \
--instance-id $instance_id \
--name \"$instance_name\"\"ForMigrationAmi-$timestamp\" \
--description \"AMI created from $instance_id for windows ZCA to Linux ZCA migration\" \
--tag-specifications \"ResourceType=image,Tags=[{Key=ZERTO_TAG,Value=ZERTO_EC2_RESOURCE},{Key=ZERTO_MIGRATION,Value=\\\"WIN-IP-${windowsZcaIp}, LINUX-IP-${linuxZcaIp}\\\"}]\" \"ResourceType=snapshot,Tags=[{Key=ZERTO_TAG,Value=ZERTO_EBS_RESOURCE},{Key=ZERTO_MIGRATION,Value=\\\"WIN-IP-${windowsZcaIp}, LINUX-IP-${linuxZcaIp}\\\"}]\" \
--no-reboot"

  logToFileOnly "About to run the create AMI command: $createAmiCommand"

   # Run the command and store the output
  instance_ami=$(eval "$createAmiCommand")
  if [ $? -ne 0 ]; then
    logToFileOnly "Failed to create AMI"
    return 1 
  fi

  # Extract the image ID from the output
  instance_ami_image_id=$(echo "$instance_ami" | jq -r '.ImageId')
  if [ -z "$instance_ami_image_id" ]; then
    logToFileOnly "Failed to extract AMI ID"
    return 1 
  fi

  logToFileOnly "Created AMI: $instance_ami_image_id"

  echo "$instance_ami_image_id"
}

waitTillAmiCreated () {
  local os_type="$1"
  local instance_ami_image_id="$2"
  
  # Timeout in seconds
  timeout=1800
  start_time=$SECONDS
  # Wait for the AMI to be available
  while true; do
    # Check the status of the AMI creation process
    ami_creation_status=$(aws ec2 describe-images --image-ids $instance_ami_image_id --query 'Images[0].State' --output text)

    if [ "$ami_creation_status" = "available" ]; then
      logNewLineToOutput
      logInfo "${GREEN}$os_type ZCA VM AMI ID: $instance_ami_image_id creation completed successfully.${NORMAL}"
      break
    elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
      logNewLineToOutput
      logError "Timeout reached while waiting for AMI $instance_ami_image_id creation."
      return 1
    else
      logDebug "Waiting for AMI $instance_ami_image_id creation to complete. Current status: $ami_creation_status..."
      logDotToOutputWithoutNewLine
      sleep 5
    fi
  done
}

terminateInstanceAsync () {
  local instance_id="$1"

  if ! aws ec2 terminate-instances --instance-ids $instance_id; then
    logError "Failed to terminate instance $instance_id"
    return 1
  fi
}

waitTillInstanceTerminated () {
  local os_type="$1"
  local instance_id="$2"

  # Timeout in seconds
  timeout=300
  start_time=$SECONDS
  # Wait for the instance to reach the "terminated" state
  while true; do
    # Query instance
    instance_info=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[].Instances[].[State.Name]')

    # Check if the instance still exists (handle cases where it is no longer available to query in AWS)
    if [ -z "$instance_info" ]; then
      logDebug "Instance $instance_id no longer exists."
      return
    fi

    instance_state=$(jq -r '.[][]' <<< "$instance_info")
    if [ "$instance_state" = "terminated" ]; then
      logNewLineToOutput
      logInfo "${GREEN}$os_type ZCA VM $instance_id has been terminated successfully.${NORMAL}"
      break
    elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
      logNewLineToOutput
      logError "Timeout reached while waiting for instance $instance_id to terminate."
      return 1
    else
      logDebug "Waiting for the instance $instance_id to terminate..."
      logDotToOutputWithoutNewLine
      sleep 5
    fi
  done
}

createInstanceFromAmi() {
  # Define named parameters
  local ami_image_id="$1"
  local nic_id="$2"
  local iam_role_arn="$3"
  local instance_type="$4"
  local key_pair="$5"
  local volumes="$6"
  local capacity_reservation="$7" 
  local placement_group="$8" 
  shift 8  # Shift past the named parameters

  # Extract tags from the remaining parameters
  local tags=("$@")  # Store remaining parameters in an array

  # Handle cases where the iam_role_arn is null or empty
  local iam_profile_arg=""
  if [ -n "$iam_role_arn" ] && [ "$iam_role_arn" != "null" ]; then
    iam_profile_arg="--iam-instance-profile Arn=$iam_role_arn"
  fi

  # Handle cases where the key_pair is provided or empty
  local key_pair_arg=""
  if [ -n "$key_pair" ] && [ "$key_pair" != "null" ]; then
    key_pair_arg="--key-name $key_pair"
  fi

  # Prepare tag specifications
  local tags_arg=""
  # Check if tags array is not empty and not null
  if [ -n "$tags" ] && [ "${#tags[@]}" -gt 0 ]; then
    tags_arg=$(jq -r '"{Key=\"\(.Key)\",Value=\"\(.Value)\"},"' <<< "${tags[@]}")
    # Remove the trailing comma
    tags_arg="${tags_arg%,}"
    tags_arg="--tag-specifications 'ResourceType=instance,Tags=[$tags_arg]'"
  fi

  # Prepare volume specifications
  local volumes_arg=""
  if [ -n "$volumes" ] && [ "$volumes" != "null" ]; then
    volumes_arg="--block-device-mappings '[$volumes]'"
  fi

  # Prepare capacity reservation specifications
  local capacity_reservation_arg=""
  if [ -n "$capacity_reservation" ] && [ "$capacity_reservation" != "null" ]; then
    capacity_prop=$(echo "$capacity_reservation" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"')
    capacity_reservation_arg="--capacity-reservation-specification $capacity_prop"
  fi

  # Prepare placement group specification
  local placement_group_arg=""
  if [ -n "$placement_group" ] && [ "$placement_group" != "null" ]; then
    placement_group_arg="--placement '$placement_group'"
  fi

  # Create instance command string
  createInstanceCommand="aws ec2 run-instances --image-id \"$ami_image_id\" --instance-type \"$instance_type\" \
    --network-interfaces '[{\"NetworkInterfaceId\":\"$nic_id\",\"DeviceIndex\":0}]' \
    $key_pair_arg $tags_arg $iam_profile_arg $volumes_arg $capacity_reservation_arg $placement_group_arg"

  logToFileOnly "About to run the create instance command: $createInstanceCommand"

   # Run the command and store the output
  if ! instance=$(eval "$createInstanceCommand"); then
    logToFileOnly "Failed to create instance"
    return 1 
  fi

  logToFileOnly "Created instance: $instance"

  # Extract the image ID from the output
  instance_id=$(echo "$instance" | jq -r '.Instances[].InstanceId')

  echo "$instance_id"
}

waitTillInstanceCreated () {
  local os_type="$1"
  local instanceId="$2"
  
  # Timeout in seconds
  timeout=1200
  start_time=$SECONDS
  # Wait for the instance to be running
  while true; do
      # Check the status of the instance
      instance_state=$(aws ec2 describe-instances --instance-ids $instanceId --query 'Reservations[0].Instances[0].State.Name' --output text)

      if [ "$instance_state" = "running" ]; then
        logNewLineToOutput
        logInfo "${GREEN}$os_type ZCA VM $instanceId has been recreated successfully.${NORMAL}"
        break
      elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
          logNewLineToOutput
          logError "Timeout reached while waiting for instance $instanceId creation."
          return 1
      else
          logDebug "Waiting for instance $instanceId creation to complete..."
          logDotToOutputWithoutNewLine
          sleep 5
      fi
  done
}

waitTillInstanceSsmReady() {
  local instanceId="$1"
  
  # Timeout in seconds
  timeout=600
  start_time=$SECONDS
  
  # Wait for the instance to have the SSM agent ready
  while true; do
      # Check the status of the SSM agent on the instance
      ssm_status=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instanceId" --output json | jq -r '.InstanceInformationList[0].PingStatus')
      
      if [ "$ssm_status" = "Online" ]; then
          logNewLineToOutput
          logDebug "SSM agent is ready on instance $instanceId."
          break
      elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
          logNewLineToOutput
          logError "Timeout reached while waiting for SSM agent on instance $instanceId."
          return 1
      else
          logDebug "Waiting for SSM agent on instance $instanceId to be ready. Current status: $ssm_status..."
          logDotToOutputWithoutNewLine
          sleep 5
      fi
  done
}

restoreVolumesTags() {
    local instance_os="$1"
    local zca_instance="$2"
    local zca_volumes_tags="$3"

    while IFS= read -r zca_instance_volume; do
        local device_name=$(jq -r '.DeviceName' <<< "$zca_instance_volume")
        if [ -n "$device_name" ]; then
            local volume_id=$(jq -r "select(.DeviceName == \"$device_name\") | .Ebs.VolumeId" <<< "$zca_instance_volume")
            local volume_tags=$(jq -r ".Volumes[] | select(.DeviceName == \"$device_name\") | .Tags | map(\"Key=\\\"\(.Key)\\\",Value=\\\"\(.Value)\\\"\") | join(\" \")" <<< "$zca_volumes_tags" | grep -v '^$')
            if [ -n "$volume_id" ] && [ -n "$volume_tags" ]; then
                createTagsCommand="aws ec2 create-tags --resources $volume_id --tags $volume_tags"
                logToFileOnly "Restoring volume tags for device_name: $device_name, command: $createTagsCommand"
                if ! eval "$createTagsCommand"; then
                  logError "Failed to CreateTags for $instance_os ZCA volume $volume_id tags $volume_tags"
                  return 1
                fi
            fi
        else
            exit 1
        fi
    done < <(jq -c '.Reservations[].Instances[].BlockDeviceMappings[]?' <<< "$zca_instance")

    logInfo "$instance_os ZCA volume tags been restored"
}

displayUsage () {
  echo "Usage: $0 --windows-zca-ip <ipv4> --linux-zca-ip <ipv4> [--recreate <recreation-params-file-path>]]"
}

validateIp () {
  local ip="$1"
  if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    logError "Invalid IP address format: $ip"
    exit 1
  fi
}

getLocationByInstanceId () {
    local instance_id="$1"
    local availability_zone=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
    local region="${availability_zone::-1}"  # Remove the last character (zone letter) to get the region

    if [ -z "$region" ]; then
        logError "Failed to retrieve region for instance: $instance_id"
        exit 1
    fi

    echo "$region"
}

getSubnetIdByInstanceId() {
    local instance_id="$1"
    local subnet_id=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].SubnetId' --output text)
    
    if [ -z "$subnet_id" ]; then
        logError "Failed to retrieve Subnet ID for instance: $instance_id"
        exit 1
    fi

    echo "$subnet_id"
}

checkSSMAgent() {
    local instanceId="$1"

    # Query AWS for SSM agent information
    local ssmInfo
    ssmInfo=$(aws ssm describe-instance-information \
              --filters "Key=InstanceIds,Values=$instanceId" \
              --output json)

    # Check if SSM agent is installed
    local isSSMInstalled
  isSSMInstalled=$(echo "$ssmInfo" | jq -r ".InstanceInformationList[] | select(.InstanceId==\"$instanceId\") | .InstanceId")

    if [ -z "$isSSMInstalled" ]; then
        logError "SSM Agent is not installed on instance $instanceId.  Cannot remove duplicated k8s nodes."
        return 1
    fi

    # Check SSM Agent status
    local agentStatus
    agentStatus=$(echo "$ssmInfo" | jq -r ".InstanceInformationList[] | select(.InstanceId==\"$instanceId\") | .PingStatus")

    if [ "$agentStatus" != "Online" ]; then
        logError "SSM Agent is not running on the Linux ZCA instace $instanceId! Cannot remove duplicated k8s nodes."
        return 1
    fi

    logDebug "SSM Agent is installed and running on instance $instanceId."
  return 0
}

deleteDuplicateK8sNodes () {
  local instanceId="$1"
    local script

  script='"#!/bin/bash",'
    script+='"set -e",'
    script+='"microk8s.kubectl delete nodes --all",'
    script+='"microk8s.kubectl delete pods --all",'
    script+='"microk8s stop",'
    script+='"microk8s start",'
    script+='"microk8s.kubectl get nodes",'
    script+='"node_count=$(microk8s.kubectl get nodes --no-headers | wc -l)",'
    script+='"if [ $node_count -eq 1 ]; then",'
    script+='" echo \"Nodes were deleted and there is only one Kubernetes node.\"",'
    script+='"else",'
    script+='" echo \"Error: Nodes were not deleted properly or there are more than one Kubernetes nodes.\"",'
    script+='"fi"'

    # Send the script via AWS SSM
    if ! sendSsmCommand "$instanceId" "$script"; then
        return 1
    fi
}

waitTillSendCommandCompleted () {
  local commandId="$1"
  # Timeout in seconds
  timeout=240
  start_time=$SECONDS
  while true; do
    # Fetch the command invocation status
    status=$(aws ssm list-command-invocations \
      --command-id "$commandId" \
      --details \
      --query "CommandInvocations[*].Status" \
      --output text)

    logDebug "Send Command current Status: $status"

    # Check the status of the command
    if [ "$status" == "Success" ]; then
      logNewLineToOutput
      logDebug "Success: SendCommand completed successfully."
      return 0
    elif [ "$status" == "Failed" ]; then
      logNewLineToOutput
      logError "Failed: SendCommand failed, command: $commandId."
      return 1
    elif [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
      logNewLineToOutput
      logError "Timeout reached while waiting for SendCommand $commandId to complete."
      return 1
    else
      logDebug "Waiting for run command $commandId to complete..."
      logDotToOutputWithoutNewLine
      sleep 5
    fi
  done
}

waitTillInstanceSsmResponding() {
  local instanceId="$1"
  
  timeout=120
  start_time=$SECONDS
      
  while true; do
    if [ "$((SECONDS - start_time))" -ge "$timeout" ]; then
      logNewLineToOutput
      logError "Timeout reached while waiting for SSM to respond."
      return 1
    fi
    
    isSsmRespondingCommandId=$(sendSsmCommand "$instanceId" "microk8s.kubectl cluster-info")
        
    if [ -n "$isSsmRespondingCommandId" ]; then
    
      # Needed to make sure Ssm is responding is completed by short timeframe. 
      # 'In progress' status may indicate k8s isn't ready yet and commands may fail afterwords.
      sleep 5
      
      # Fetch the command invocation status
      status=$(aws ssm list-command-invocations \
        --command-id "$isSsmRespondingCommandId" \
        --details \
        --query "CommandInvocations[*].Status" \
        --output text)

      logDebug "Instance Ssm Responding check command current Status: $status, instanceId: $instanceId."

      # Verify k8s response completed successfully 
      if [ "$status" == "Success" ]; then
        logNewLineToOutput
        logInfo "Success: SSM is responding, instanceId: $instanceId."
        return 0
      fi
    fi
    
    logDebug "Waiting for Instance Ssm Responding check command $isSsmRespondingCommandId to complete."
    logDotToOutputWithoutNewLine
    sleep 5
  done
}

sendSsmCommand() {
    local instanceId="$1"
    local script="$2"

    # Send the script via AWS SSM
    commandId=$(aws ssm send-command \
        --instance-ids "$instanceId" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=$script" \
        --query "Command.CommandId" \
        --output text)

    if [ $? -ne 0 ]; then
        logError "Failed to send the SSM command on instance $instanceId"
        return 1
    fi

    echo $commandId
}

step_queue=()
function_queue=()
addRollbackStep(){
    step=$1
    func=$2

    step_queue+=("$step")
    function_queue+=("$func")
}

executeRollback(){
  logInfo "${YELLOW}Error occurred...${NORMAL}"

  for ((i=${#function_queue[@]}-1; i>=0; i--)); do
      rollbackIndex=$i
      item="${function_queue[i]}"
      step="${step_queue[i]}"
      stepIndex=$((i+1))

      IFS=' ' read -ra parts <<< "$item"
      function_name="${parts[0]}"
      parameters="${parts[@]:1}"

      logInfo "- undo step #$stepIndex: $step"
      $function_name ${parameters[@]} || return 1
  done

  logInfo "${YELLOW}Script steps were successfully rolled back${NORMAL}"
}

showRollbackLeftoverSteps(){
  logInfo "${YELLOW}Rollback steps that require manual execution:${NORMAL}"

  for ((i=$rollbackIndex-1; i>=0; i--)); do
      step="${step_queue[i]}"
      stepIndex=$((i+1))

      logInfo "- step #$stepIndex: $step"
  done
}

# Parse options
options=$(getopt -o "" -l windows-zca-ip:,linux-zca-ip:,verbose,recreate: -n "$0" -- "$@")
if [ $? -ne 0 ]; then
  displayUsage
  exit 1
fi
eval set -- "$options"

while true; do
  case "$1" in
  --windows-zca-ip) windowsZcaIp="$2"; shift 2 ;;
  --linux-zca-ip) linuxZcaIp="$2"; shift 2 ;;
  --verbose) __VERBOSE=1; shift ;;
  --recreate) __RECREATE=1; recreation_params_file="$2"; shift 2 ;;
  --) shift; break ;;
  *) displayUsage; exit 1 ;;
  esac
done

# Check if required parameters are missing
if [[ -z "$windowsZcaIp" || -z "$linuxZcaIp" ]]; then
  logError "Missing required parameter(s)."
  displayUsage
  exit 1
fi

# Validate IP formats
validateIp "$windowsZcaIp"
validateIp "$linuxZcaIp"

# Validate IP uniqueness
if [[ "$windowsZcaIp" == "$linuxZcaIp" ]]; then
  logError "Each VM IP address input must be unique"
  exit 1
fi

#If not recreate mode
if [[ $__RECREATE -eq 0 ]]; then
  
  #1. Init variables (and extract instances properties such as NIC, name, IAM etc.)
  logInfo "1. Initialization..."

  linux_zca=$(aws ec2 describe-instances --filters "Name=private-ip-address,Values=$linuxZcaIp")
  if [ "$(jq -r '.Reservations | length' <<< "$linux_zca")" -ne 1 ]; then
    # Handle the case where no instances with the given IP address exist
    logError "Instance with private IP address $linuxZcaIp not found"
    exit 1
  fi
  logToFileOnly "Original linux_zca instance: $linux_zca"
  linux_nic=$(jq -r '.Reservations[].Instances[].NetworkInterfaces[0]' <<< "$linux_zca")
  linux_nic_id=$(jq -r '.NetworkInterfaceId' <<< "$linux_nic")
  if [ "$linux_nic_id" = "null" ]; then
      logError "NIC with $linuxZcaIp not found"
      exit 1
  fi
  linux_zca_instance_id=$(jq -r '.Reservations[].Instances[].InstanceId' <<< "$linux_zca")
  linux_zca_tags=$(getInstanceFilteredAwsTags "$linux_zca")
  linux_zca_instance_type=$(jq -r '.Reservations[].Instances[].InstanceType' <<< "$linux_zca")
  linux_nic_attachmentId=$(jq -r '.Attachment.AttachmentId' <<< "$linux_nic")
  linux_original_delete_on_termination_for_nic=$(jq -r '.Attachment.DeleteOnTermination' <<< "$linux_nic")
  linux_zca_iam_role_arn=$(jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' <<< "$linux_zca")
  linux_zca_instance_key_pair=$(jq -r '.Reservations[].Instances[].KeyName' <<< "$linux_zca")
  linux_zca_capacity_reservation=$(jq -c '.Reservations[].Instances[].CapacityReservationSpecification' <<< "$linux_zca")
  linux_zca_placement_info=$(fetchPlacementInfo "$linux_zca")
  linux_zca_volume_ids=$(jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId // empty' <<< "$linux_zca" | grep -v "^$")
  linux_zca_volumes_info=$(aws ec2 describe-volumes --volume-ids $linux_zca_volume_ids)
  logToFileOnly "volumes_info: $linux_zca_volumes_info"
  linux_zca_volumes_tags=$(fetchVolumesTags "$linux_zca_volumes_info")
  linux_zca_volumes=$(fetchVolumeMetadata "$linux_zca" "$linux_zca_volumes_info")
  linux_original_zca_disable_api_termination=$(aws ec2 describe-instance-attribute --instance-id "$linux_zca_instance_id" --attribute disableApiTermination --query 'DisableApiTermination.Value')
  linux_original_zca_initiated_shutdown_behavior=$(aws ec2 describe-instance-attribute --instance-id "$linux_zca_instance_id" --attribute instanceInitiatedShutdownBehavior --query 'InstanceInitiatedShutdownBehavior.Value')
  linux_original_zca_disable_api_stop=$(aws ec2 describe-instance-attribute --instance-id "$linux_zca_instance_id" --attribute disableApiStop --query 'DisableApiStop.Value')
  printInstanceProperties $linux_os \
                          "$linux_zca_instance_id" \
                          "$linux_nic_id" \
                          "$linux_nic_attachmentId" \
                          "$linux_original_delete_on_termination_for_nic" \
                          "$linux_zca_iam_role_arn" \
                          "$linux_zca_instance_type" \
                          "$linux_zca_instance_key_pair" \
                          "$linux_original_zca_disable_api_termination" \
                          "$linux_original_zca_initiated_shutdown_behavior" \
                          "$linux_original_zca_disable_api_stop" \
                          "$linux_zca_capacity_reservation" \
                          "$linux_zca_placement_info" \
                          "$linux_zca_volumes" \
                          "$linux_zca_volumes_tags" \
                          "$linux_zca_tags"

  win_zca=$(aws ec2 describe-instances --filters "Name=private-ip-address,Values=$windowsZcaIp")
  if [ "$(jq -r '.Reservations | length' <<< "$win_zca")" -ne 1 ]; then
    # Handle the case where no instances with the given IP address exist
    logError "Instance with private IP address $windowsZcaIp not found"
    exit 1
  fi
  win_nic=$(jq -r '.Reservations[].Instances[].NetworkInterfaces[0]' <<< "$win_zca")
  win_nic_id=$(jq -r '.NetworkInterfaceId' <<< "$win_nic")
  if [ "$win_nic_id" = "null" ]; then
      logError "NIC with $windowsZcaIp not found"
      exit 1
  fi
  logToFileOnly "Original win_zca instance: $win_zca"
  win_zca_instance_id=$(jq -r '.Reservations[].Instances[].InstanceId' <<< "$win_zca")
  win_zca_tags=$(getInstanceFilteredAwsTags "$win_zca")
  win_zca_instance_type=$(jq -r '.Reservations[].Instances[].InstanceType' <<< "$win_zca")
  win_nic_attachmentId=$(jq -r '.Attachment.AttachmentId' <<< "$win_nic")
  win_original_delete_on_termination_for_nic=$(jq -r '.Attachment.DeleteOnTermination' <<< "$win_nic")
  win_zca_iam_role_arn=$(jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' <<< "$win_zca")
  win_zca_instance_key_pair=$(jq -r '.Reservations[].Instances[].KeyName' <<< "$win_zca")
  win_zca_capacity_reservation=$(jq -c '.Reservations[].Instances[].CapacityReservationSpecification' <<< "$win_zca")
  win_zca_placement_info=$(fetchPlacementInfo "$win_zca")
  win_zca_volume_ids=$(jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId // empty' <<< "$win_zca" | grep -v "^$")
  win_zca_volumes_info=$(aws ec2 describe-volumes --volume-ids $win_zca_volume_ids)
  logToFileOnly "volumes_info: $win_zca_volumes_info"
  win_zca_volumes_tags=$(fetchVolumesTags "$win_zca_volumes_info")
  win_zca_volumes=$(fetchVolumeMetadata "$win_zca" "$win_zca_volumes_info")
  win_original_zca_disable_api_termination=$(aws ec2 describe-instance-attribute --instance-id "$win_zca_instance_id" --attribute disableApiTermination --query 'DisableApiTermination.Value')
  win_original_zca_initiated_shutdown_behavior=$(aws ec2 describe-instance-attribute --instance-id "$win_zca_instance_id" --attribute instanceInitiatedShutdownBehavior --query 'InstanceInitiatedShutdownBehavior.Value')
  win_original_zca_disable_api_stop=$(aws ec2 describe-instance-attribute --instance-id "$win_zca_instance_id" --attribute disableApiStop --query 'DisableApiStop.Value')
  
  printInstanceProperties $windows_os \
                          "$win_zca_instance_id" \
                          "$win_nic_id" \
                          "$win_nic_attachmentId" \
                          "$win_original_delete_on_termination_for_nic" \
                          "$win_zca_iam_role_arn" \
                          "$win_zca_instance_type" \
                          "$win_zca_instance_key_pair" \
                          "$win_original_zca_disable_api_termination" \
                          "$win_original_zca_initiated_shutdown_behavior" \
                          "$win_original_zca_disable_api_stop" \
                          "$win_zca_capacity_reservation" \
                          "$win_zca_placement_info" \
                          "$win_zca_volumes" \
                          "$win_zca_volumes_tags" \
                          "$win_zca_tags"
    
  #2. Validations 
  #Validate same regions
  win_region_name=$(getLocationByInstanceId "$win_zca_instance_id")
  logDebug "Windows ZCA Region name: ${GREEN}$win_region_name${NORMAL}"

  linux_region_name=$(getLocationByInstanceId "$linux_zca_instance_id")
  logDebug "Linux ZCA Region name: ${GREEN}$linux_region_name${NORMAL}"

  if [[ "$win_region_name" != "$linux_region_name" ]]; then
    logError "The Linux ZCA VM and the Windows ZCA VM are not located in the same region. To execute the migration process, both the Linux ZCA VM and the Windows ZCA VM must be located in the same region."
    exit 1
  fi

  #Validate same subnets
  win_subnet_id=$(getSubnetIdByInstanceId "$win_zca_instance_id")
  logDebug "Windows ZCA subnet ID: ${GREEN}$win_subnet_id${NORMAL}"

  linux_subnet_id=$(getSubnetIdByInstanceId "$linux_zca_instance_id")
  logDebug "Linux ZCA subnet ID: ${GREEN}$linux_subnet_id${NORMAL}"

  if [ "$win_subnet_id" != "$linux_subnet_id" ]; then
    logError "The Linux ZCA VM and the Windows ZCA VM are not located in the same subnet. To execute the migration process, both the Linux ZCA VM and the Windows ZCA VM must be located in the same subnet."
    exit 1
  fi

  # Validate SSM is available on the Linux ZCA instance
  if ! checkSSMAgent "$linux_zca_instance_id"; then
    logError "SSM is not available. The VM may be shut down, or the user executing the script might not have the required permissions. See Zerto documentation for more information."
    exit 1
  fi

  #3. Set the termination behavior
  # Set termination behavior for both primary NICs
  {
    setDeleteOnTerminationForNic $linux_os $linux_nic_id $linux_nic_attachmentId false $linux_original_delete_on_termination_for_nic &&
    addRollbackStep "Set delete-on-termination for NIC $linux_nic_id to its original value" \
      "setDeleteOnTerminationForNic $linux_os $linux_nic_id $linux_nic_attachmentId $linux_original_delete_on_termination_for_nic false" &&

    setAttributeForInstanceIfNeeded $linux_os $linux_zca_instance_id disable-api-termination false $linux_original_zca_disable_api_termination true &&
    addRollbackStep "Set disable-api-termination for instance $linux_zca_instance_id to its original value" \
      "setAttributeForInstanceIfNeeded $linux_os $linux_zca_instance_id disable-api-termination $linux_original_zca_disable_api_termination false true" &&

    setAttributeForInstanceIfNeeded $linux_os $linux_zca_instance_id disable-api-stop false $linux_original_zca_disable_api_stop  true &&
    addRollbackStep "Set disable-api-stop for instance $linux_zca_instance_id to its original value" \
      "setAttributeForInstanceIfNeeded $linux_os $linux_zca_instance_id disable-api-stop $linux_original_zca_disable_api_stop false true"
  } &&

  {
    setDeleteOnTerminationForNic $windows_os $win_nic_id $win_nic_attachmentId false $win_original_delete_on_termination_for_nic &&
    addRollbackStep "Set delete-on-termination for NIC $linux_nic_id to its original value" \
      "setDeleteOnTerminationForNic $windows_os $win_nic_id $win_nic_attachmentId $win_original_delete_on_termination_for_nic false" &&

    setAttributeForInstanceIfNeeded $windows_os $win_zca_instance_id disable-api-termination false $win_original_zca_disable_api_termination true &&
    addRollbackStep "Set disable-api-termination for instance $win_zca_instance_id termination to its original state" \
      "setAttributeForInstanceIfNeeded $windows_os $win_zca_instance_id disable-api-termination $win_original_zca_disable_api_termination false true" &&
    
    setAttributeForInstanceIfNeeded $windows_os $win_zca_instance_id disable-api-stop false $win_original_zca_disable_api_stop true &&
    addRollbackStep "Set disable-api-stop for instance $win_zca_instance_id to its original state" \
      "setAttributeForInstanceIfNeeded $windows_os $win_zca_instance_id disable-api-stop $win_original_zca_disable_api_stop false true"
  } &&

  #4. Power off ZCA instances
  {
    stopInstanceAsync $linux_zca_instance_id &&
    addRollbackStep "starting Linux ZCA" \
      "startInstanceAsync $linux_zca_instance_id" &&
    stopInstanceAsync $win_zca_instance_id &&
    addRollbackStep "starting Windows ZCA" \
      "startInstanceAsync $win_zca_instance_id" &&
    
    waitTillInstanceStopped $linux_os $linux_zca_instance_id &&
    waitTillInstanceStopped $windows_os $win_zca_instance_id
  } &&
  
  #5. Take an AMI backup for both instances
  {
    logInfo "${GREEN}Creating AMI from Linux ZCA${NORMAL}"
    linux_zca_ami_image_id=$(createAmiAsync $linux_zca_instance_id "LinuxZca" "$windowsZcaIp" "$linuxZcaIp") &&

    logInfo "${GREEN}Creating AMI from Windows ZCA${NORMAL}" &&
    win_zca_ami_image_id=$(createAmiAsync $win_zca_instance_id "WindowsZca" "$windowsZcaIp" "$linuxZcaIp") &&

    waitTillAmiCreated $linux_os "$linux_zca_ami_image_id" &&
    waitTillAmiCreated $windows_os "$win_zca_ami_image_id"
  } &&
  #6. Write parameters to file
  {  
    logInfo "${GREEN}Writing recreation info to file $recreation_params_file${NORMAL}"
    
    recreation_params=$(cat <<-EOF
linux_zca_ami_image_id:$linux_zca_ami_image_id
linux_zca_instance_id: $linux_zca_instance_id
linux_nic_id:$linux_nic_id
linux_zca_iam_role_arn:$linux_zca_iam_role_arn
linux_zca_instance_type:$linux_zca_instance_type
linux_zca_instance_key_pair:$linux_zca_instance_key_pair
linux_zca_volumes:$linux_zca_volumes
linux_zca_capacity_reservation:$linux_zca_capacity_reservation
linux_zca_placement_info:$linux_zca_placement_info
linux_zca_tags:$linux_zca_tags
linux_original_delete_on_termination_for_nic:$linux_original_delete_on_termination_for_nic
linux_zca_volumes_tags:$linux_zca_volumes_tags
linux_original_zca_disable_api_termination:$linux_original_zca_disable_api_termination
linux_original_zca_disable_api_stop:$linux_original_zca_disable_api_stop
linux_original_zca_initiated_shutdown_behavior:$linux_original_zca_initiated_shutdown_behavior
win_zca_ami_image_id:$win_zca_ami_image_id
win_zca_instance_id: $win_zca_instance_id
win_nic_id:$win_nic_id
win_zca_iam_role_arn:$win_zca_iam_role_arn
win_zca_instance_type:$win_zca_instance_type
win_zca_instance_key_pair:$win_zca_instance_key_pair
win_zca_volumes:$win_zca_volumes
win_zca_capacity_reservation:$win_zca_capacity_reservation
win_zca_placement_info:$win_zca_placement_info
win_zca_tags:$win_zca_tags
win_original_delete_on_termination_for_nic:$win_original_delete_on_termination_for_nic
win_zca_volumes_tags:$win_zca_volumes_tags
win_original_zca_disable_api_termination:$win_original_zca_disable_api_termination
win_original_zca_disable_api_stop:$win_original_zca_disable_api_stop
win_original_zca_initiated_shutdown_behavior:$win_original_zca_initiated_shutdown_behavior
EOF
    ) &&
    
    echo -e "$recreation_params" > "$recreation_params_file"
  } &&
    
  #7. Terminate the ZCA instances (to release the NICs)
  {
    logInfo "${GREEN}Terminating Linux ZCA${NORMAL}"
    terminateInstanceAsync $linux_zca_instance_id &&
    
    logInfo "${GREEN}Terminating Windows ZCA${NORMAL}" &&
    terminateInstanceAsync $win_zca_instance_id
  } ||
  # Rollback option is only till the termination command been sent, after that, we should try to run the recreate (manually as a second run of the script)
  {
    executeRollback &&
    logError "Windows and Linux ZCAs NIC were not switched" &&
    logInfo "${YELLOW}Monitor script messages to track failed steps, resolve issues and re-run the script. If the issue persists, please contact support${NORMAL}" &&
    exit 1
  } ||
  {
    logError "Windows and Linux ZCAs NIC were not switched"
    logInfo "${RED}Rollback was not executed properly.${NORMAL}"
    logInfo "${YELLOW}Monitor script messages to track failed steps${NORMAL}"
    showRollbackLeftoverSteps
    exit 1
  } 
  
  waitTillInstanceTerminated $linux_os $linux_zca_instance_id &&
  waitTillInstanceTerminated $windows_os $win_zca_instance_id ||
  {
    logError "Instances were terminated. Not executing a rollback" &&
    logInfo "${YELLOW}Resolve issues and execute the script again with the following command:${NORMAL}" &&
    logInfo "${YELLOW}./reassign-nic.bash --windows-zca-ip $windowsZcaIp --linux-zca-ip $linuxZcaIp --recreate $recreation_params_file${NORMAL}" &&
    exit 1
  }
else
  # Check if required parameters are missing or if the file does not exist
  if [ -z "$recreation_params_file" ] || [ ! -f "$recreation_params_file" ]; then
    logError "Missing required parameter [recreation-params-file-path] or file does not exist."
    displayUsage
    exit 1
  fi
  {
    logInfo "${GREEN}Starting instances recreation.${NORMAL}"
    logInfo "${GREEN}Reading recreation info from file $recreation_params_file${NORMAL}"
    
    # Read params file and create variables
    while IFS=":" read -r key value; do
      logToFileOnly "Declearing parameter: $key=$value"
      declare "$key=$value"
      if [ $? -ne 0 ]; then
        logError "There is an issue reading the parameters files for the recreate option"
        exit 1
      fi
    done < "$recreation_params_file"
  } ||
  {
    logError "There is an issue reading the parameters files for the recreate option"
    exit 1
  }
fi  

# Starting from this point onward, the script proceeds with a common section that applies to both cases
#8. Launch a new instance from the Linux AMI with the windows ZCA's NIC (including restoring instance properties like name, IAM etc.)
#   and new instance from the windows AMI with the linux's NIC (including restoring instance properties like name, IAM etc.)
{
  if [ -z "$win_zca_new_instance_id" ]; then
    logInfo "${GREEN}Creating Windows instance with the NIC that was attached to the Linux instance $linux_nic_id.${NORMAL}"
    win_zca_new_instance_id=$(createInstanceFromAmi "$win_zca_ami_image_id" "$linux_nic_id" "$win_zca_iam_role_arn" "$win_zca_instance_type" \
      "$win_zca_instance_key_pair" "$win_zca_volumes" "$win_zca_capacity_reservation" "$win_zca_placement_info" "$win_zca_tags") &&
    echo -e "win_zca_new_instance_id:$win_zca_new_instance_id" >> $recreation_params_file
  else
    logDebug "Skipping Windows instance creation as it was already created in a previous run. Current win_zca_new_instance_id: $win_zca_new_instance_id"
  fi &&

  if [ -z "$linux_zca_new_instance_id" ]; then
    logInfo "${GREEN}Creating Linux instance with the NIC that was attached to the Windows instance $win_nic_id.${NORMAL}"
    linux_zca_new_instance_id=$(createInstanceFromAmi "$linux_zca_ami_image_id" "$win_nic_id" "$linux_zca_iam_role_arn" "$linux_zca_instance_type" \
      "$linux_zca_instance_key_pair" "$linux_zca_volumes" "$linux_zca_capacity_reservation" "$linux_zca_placement_info" "$linux_zca_tags") &&
    echo -e "linux_zca_new_instance_id:$linux_zca_new_instance_id" >> $recreation_params_file
  else
    logDebug "Skipping Linux instance creation as it was already created in a previous run. Current linux_zca_new_instance_id: $linux_zca_new_instance_id"
  fi &&

  waitTillInstanceCreated $windows_os $win_zca_new_instance_id &&
  waitTillInstanceCreated $linux_os $linux_zca_new_instance_id &&
  waitTillInstanceSsmReady $linux_zca_new_instance_id &&
  sleep 5
} &&

#9. Restore properties
#  Restore the termination behavior of both primary NICs of both instances (since the NIC now attach to a different instance, 
#  restore the value to the one that was set to the new instance)
{
  new_linux_zca=$(aws ec2 describe-instances --instance-ids $linux_zca_new_instance_id) &&
  new_linux_nic_attachmentId=$(echo "$new_linux_zca" | jq -r '.Reservations[].Instances[].NetworkInterfaces[].Attachment.AttachmentId') &&
  setDeleteOnTerminationForNic $linux_os $win_nic_id $new_linux_nic_attachmentId $win_original_delete_on_termination_for_nic "false"
} &&
{
  new_win_zca=$(aws ec2 describe-instances --instance-ids $win_zca_new_instance_id) &&
  new_win_nic_attachmentId=$(echo "$new_win_zca" | jq -r '.Reservations[].Instances[].NetworkInterfaces[].Attachment.AttachmentId') &&
  setDeleteOnTerminationForNic $windows_os $linux_nic_id $new_win_nic_attachmentId $linux_original_delete_on_termination_for_nic "false"
} &&

{
  # Restore termination behavior for both instances
  setAttributeForInstanceIfNeeded $linux_os $linux_zca_new_instance_id "disable-api-termination" $linux_original_zca_disable_api_termination "false" "true" &&
  setAttributeForInstanceIfNeeded $windows_os $win_zca_new_instance_id "disable-api-termination" $win_original_zca_disable_api_termination "false" "true" &&
  setAttributeForInstanceIfNeeded $linux_os $linux_zca_new_instance_id "disable-api-stop" $linux_original_zca_disable_api_stop "false" "true" &&
  setAttributeForInstanceIfNeeded $windows_os $win_zca_new_instance_id "disable-api-stop" $win_original_zca_disable_api_stop "false" "true" &&
  setAttributeForInstanceIfNeeded $linux_os $linux_zca_new_instance_id "instance-initiated-shutdown-behavior" $linux_original_zca_initiated_shutdown_behavior "stop" "false" &&
  setAttributeForInstanceIfNeeded $windows_os $win_zca_new_instance_id "instance-initiated-shutdown-behavior" $win_original_zca_initiated_shutdown_behavior "stop" "false"
} &&

{
  #Restore volumes tags
  restoreVolumesTags $linux_os "$new_linux_zca" "$linux_zca_volumes_tags" &&
  restoreVolumesTags $windows_os "$new_win_zca" "$win_zca_volumes_tags"
} &&

#10. Delete duplicate K8s nodes on Linux ZCA. 
#  When creating an AMI from the Linux ZCA and then creating an instance from that AMI, a new k8s node
#  is created because the node's name is defined by the instance IP (which changes)
 {
   sleep 5
   waitTillInstanceSsmResponding $linux_zca_new_instance_id &&
   sleep 5 &&
   deleteDuplicatesCommandId=$(deleteDuplicateK8sNodes $linux_zca_new_instance_id) &&
   waitTillSendCommandCompleted $deleteDuplicatesCommandId &&
   logInfo "Deleted k8s duplicated nodes on the Linux ZCA successfully"
 } &&

# Print results
{
  logInfo "${GREEN}Windows ZCA NIC was assigned to Linux ZCA VM${NORMAL}"
  logInfo "To connect to Windows ZCA use ${GREEN}$linuxZcaIp${NORMAL}"
  logInfo "To connect to Linux ZCA use ${GREEN}$windowsZcaIp${NORMAL}"
  logInfo "To undo changes you can use the following command:"
  logInfo " -> $0 --windows-zca-ip $linuxZcaIp --linux-zca-ip $windowsZcaIp"
  logInfo "Original instances with IDs: $win_zca_instance_id, $linux_zca_instance_id were terminated, any reference to those IDs should be updated manually"
  logInfo "New Windows instance ID: $win_zca_new_instance_id, New Linux instance ID: $linux_zca_new_instance_id"
} ||

{
  if [[ $__RECREATE -eq 0 ]]; then
    logInfo "${RED}Instances were terminated. Not executing a rollback${NORMAL}"
  else
    logInfo "${RED}Recreate failed${NORMAL}"
  fi &&
  logInfo "${YELLOW}Resolve issues and execute the script again with the following command:${NORMAL}" &&
  logInfo "${YELLOW}./reassign-nic.bash --windows-zca-ip $windowsZcaIp --linux-zca-ip $linuxZcaIp --recreate $recreation_params_file${NORMAL}" &&
  exit 1
}

logInfo "${GREEN}Execution finished${NORMAL}"
