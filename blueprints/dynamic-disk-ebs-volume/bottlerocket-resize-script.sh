#!/bin/bash
set -e

get_imds_token() {
    curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --max-time 10 --retry 3
}

get_metadata() {
    local path=$1
    local token=$2
    curl -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/$path" \
        --max-time 10 --retry 3
}

# Get target size based on instance size suffix
get_target_size_by_suffix() {
    local instance_type=$1
    local size_suffix=$(echo $instance_type | sed 's/.*\.//')

    case $size_suffix in
        nano)
            echo 20
            ;;
        micro)
            echo 30
            ;;
        small)
            echo 40
            ;;
        medium)
            echo 60
            ;;
        large)
            echo 100
            ;;
        xlarge)
            echo 200
            ;;
        2xlarge)
            echo 300
            ;;
        3xlarge)
            echo 400
            ;;
        4xlarge)
            echo 500
            ;;
        6xlarge)
            echo 600
            ;;
        8xlarge|9xlarge)
            echo 800
            ;;
        12xlarge)
            echo 1000
            ;;
        16xlarge|18xlarge)
            echo 1200
            ;;
        24xlarge)
            echo 1500
            ;;
        32xlarge|48xlarge|56xlarge|112xlarge)
            echo 2000
            ;;
        metal)
            echo 1000  # Bare metal instances
            ;;
        *)
            echo 100   # Default for unknown sizes
            ;;
    esac
}

resize_ebs_for_instance() {
    local device="/dev/xvdb"

    local token=$(get_imds_token)
    if [ -z "$token" ]; then
        echo "Failed to get IMDSv2 token"
        return 1
    fi

    local instance_id=$(get_metadata "instance-id" "$token")
    local region=$(get_metadata "placement/region" "$token")
    local instance_type=$(get_metadata "instance-type" "$token")

    if [ -z "$instance_id" ] || [ -z "$region" ] || [ -z "$instance_type" ]; then
        echo "Failed to get required metadata"
        return 1
    fi

    # Get target size based on instance suffix
    local target_size=$(get_target_size_by_suffix "$instance_type")
    local size_suffix=$(echo $instance_type | sed 's/.*\.//')

    echo "Instance: $instance_type (suffix: $size_suffix) -> Target: ${target_size}GB"

    local volume_id=$(aws ec2 describe-instances --instance-ids $instance_id \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`'$device'`].Ebs.VolumeId' \
        --output text --region $region)

    if [ -z "$volume_id" ] || [ "$volume_id" = "None" ]; then
        echo "Error: Could not find volume for device $device"
        return 1
    fi

    local current_size=$(aws ec2 describe-volumes --volume-ids $volume_id \
        --query 'Volumes[0].Size' --output text --region $region)

    if [ "$current_size" -ge "$target_size" ]; then
        echo "Volume already correct size (${current_size}GB)"
        return 0
    fi

    echo "Resizing volume from ${current_size}GB to ${target_size}GB"
    aws ec2 modify-volume --volume-id $volume_id --size $target_size --region $region

    # Wait for completion with timeout and exponential backoff
    local timeout=300
    local elapsed=0
    local wait_time=2

    while [ $elapsed -lt $timeout ]; do
        local state=$(aws ec2 describe-volumes-modifications --volume-ids $volume_id \
            --query 'VolumesModifications[0].ModificationState' --output text --region $region)

        if [[ "$state" = "completed" || "$state" = "optimizing" ]]; then
            echo "Volume modification completed"
            break
        elif [ "$state" = "failed" ]; then
            echo "Volume modification failed"
            return 1
        fi

        echo "Volume modification in progress (state: $state), waiting ${wait_time}s..."
        sleep $wait_time
        elapsed=$((elapsed + wait_time))
        
        # Exponential backoff with max of 30 seconds
        wait_time=$((wait_time * 2))
        [ $wait_time -gt 30 ] && wait_time=30
    done

    if [ $elapsed -ge $timeout ]; then
        echo "Timeout waiting for volume modification"
        return 1
    fi

    # Note: For Bottlerocket, we don't need to manually resize the filesystem
    # as Bottlerocket handles this automatically on reboot
    
    echo "EBS resize completed successfully"
    return 0
}

# Execute resize
if ! resize_ebs_for_instance; then
    echo "EBS resize failed"
fi