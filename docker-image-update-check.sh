#!/bin/bash

# Example usage:
# ./docker-image-update-check.sh

# =====================================================================================
# Configuration
# -------------------------------------------------------------------------------------
DEBUG=false
# -------------------------------------------------------------------------------------
# Docker manifest config
# -------------------------------------------------------------------------------------
ARCHITECTURE=amd64
OS=linux
# -------------------------------------------------------------------------------------
# Influx config
# -------------------------------------------------------------------------------------
INFLUX_HOST=YOUR_INFLUX_HOST
INFLUX_PORT=YOUR_INFLUX_PORT # 8086
INFLUX_ORG=YOUR_INFLUX_ORG
INFLUX_BUCKET=YOUR_INFLUX_BUCKET
INFLUX_TOKEN=YOUR_INFLUX_TOKEN
# -------------------------------------------------------------------------------------

log() {
    if [ "$DEBUG" == "true" ] ; then
        echo "$@"
    fi
}

file() {
    if [ "$DEBUG" == "true" ] ; then
        echo "$1" > "$2"
    fi
}

# =====================================================================================
# check if all required tools are installed
# -------------------------------------------------------------------------------------
# Input variables:
# - required utills
# -------------------------------------------------------------------------------------
# Output variables:
# None
check_requirements() {
    log "check_requirements: $1"
    for TOOL_NAME in $1 ; do
        log "check_requirements: TOOL_NAME=$TOOL_NAME"
        local TOOL_PATH=$(which $TOOL_NAME)
        if [ -z "$TOOL_PATH" ] ; then
            apt install -y $TOOL_NAME
            # echo "Could not find required tool: $TOOL_NAME" 1>&2
            # echo "To use this script, you need to install the following tools:" 1>&2
            # echo "  $1" 1>&2
            # exit 1
        fi
    done
}

# =====================================================================================
# check if first part of image name contains a dot, then it's a registry domain and 
# not from hub.docker.com
# -------------------------------------------------------------------------------------
# Input variables:
# - image name
# -------------------------------------------------------------------------------------
# Output variables:
IMAGE_REGISTRY=""
IMAGE_REGISTRY_API=""
IMAGE_PATH_FULL=""
detect_docker_registry_info() {
    log "detect_docker_registry_info: $1"
    if [[ $(echo $1 | cut -d : -f 1 | cut -d / -f 1) == *"."* ]] ; then
        IMAGE_REGISTRY=$(echo $1 | cut -d / -f 1)
        IMAGE_REGISTRY_API=$IMAGE_REGISTRY
        IMAGE_PATH_FULL=$(echo $1 | cut -d / -f 2-)
    elif [[ $(echo $1 | awk -F"/" '{print NF-1}') == 0 ]] ; then
        IMAGE_REGISTRY="docker.io"
        IMAGE_REGISTRY_API="registry-1.docker.io"
        IMAGE_PATH_FULL=library/$1
    else
        IMAGE_REGISTRY="docker.io"
        IMAGE_REGISTRY_API="registry-1.docker.io"
        IMAGE_PATH_FULL=$1
    fi
    log "detect_docker_registry_info: IMAGE_REGISTRY=$IMAGE_REGISTRY"
    log "detect_docker_registry_info: IMAGE_REGISTRY_API=$IMAGE_REGISTRY_API"
    log "detect_docker_registry_info: IMAGE_PATH_FULL=$IMAGE_PATH_FULL"
}

# =====================================================================================
# detect image tag
# -------------------------------------------------------------------------------------
# Input variables:
# - image full path, ex: library/nginx
# - image name, ex: nginx
# -------------------------------------------------------------------------------------
# Output variables:
IMAGE_PATH=""
IMAGE_TAG=""
IMAGE_LOCAL=""
detect_docker_image_tag() {
    log "detect_docker_image_tag: $1 $2"
    if [[ "$1" == *":"* ]] ; then
        IMAGE_PATH=$(echo $1 | cut -d : -f 1)
        IMAGE_TAG=$(echo $1 | cut -d : -f 2)
        IMAGE_TAG="latest"
        IMAGE_LOCAL="$2"
    else
        IMAGE_PATH=$1
        IMAGE_TAG="latest"
        IMAGE_LOCAL="$2:latest"
    fi
    log "detect_docker_image_tag: IMAGE_PATH=$IMAGE_PATH"
    log "detect_docker_image_tag: IMAGE_TAG=$IMAGE_TAG"
    log "detect_docker_image_tag: IMAGE_LOCAL=$IMAGE_LOCAL"
}

# =====================================================================================
# check local digest first
# -------------------------------------------------------------------------------------
# Input variables:
# - image path with tag, ex: nginx:lates
# -------------------------------------------------------------------------------------
# Output variables:
DIGEST_LOCAL=""
get_local_docker_image_digest() {
    log "get_local_docker_image_digest: $1"
    local MANIFEST=$(docker inspect $1)
    file "$MANIFEST" ../local_manifest.json
    REPO_DIGEST=$(jq -r "try .[] | select(.Architecture | contains(\"$ARCHITECTURE\")) | .RepoDigests[0] // empty" <<< $MANIFEST)
    log "get_local_docker_image_digest: REPO_DIGEST=$REPO_DIGEST"
    DIGEST_LOCAL=$(echo $REPO_DIGEST | cut -d @ -f 2)
    log "get_local_docker_image_digest: DIGEST_LOCAL=$DIGEST_LOCAL"
}

# =====================================================================================
# check remote digest
# -------------------------------------------------------------------------------------
# Input variables:
# - image path, ex: library/nginx
# -------------------------------------------------------------------------------------
# Output variables:
DIGEST_REMOTE=""
VERSION_REMOTE=""
get_remote_docker_image_digest() {
    log "get_remote_docker_image_digest: $1"
    local MANIFEST=$(docker buildx imagetools inspect $1 --format '{{json .Manifest}}')
    file "$MANIFEST" ../remote_manifest.json
    DIGEST_REMOTE=$(jq -r "try .digest // empty" <<< $MANIFEST)
    log "get_remote_docker_image_digest: DIGEST_REMOTE=$DIGEST_REMOTE"
    VERSION_REMOTE=$(jq -r "try .manifests[] | select(.platform.architecture | contains(\"$ARCHITECTURE\")) | select(.platform.os | contains(\"$OS\")) | .annotations[\"org.opencontainers.image.version\"] // \"unknown\"" <<< $MANIFEST)
    if [ -z "${VERSION_REMOTE}" ] ; then
        VERSION_REMOTE="unknown"
    fi
    log "get_remote_docker_image_digest: VERSION_REMOTE=$VERSION_REMOTE"
}

# =====================================================================================
# check docker image update availability
# -------------------------------------------------------------------------------------
# Input variables:
# - image name, ex: nginx
# - command for update available case
# - command for no updates available case
# -------------------------------------------------------------------------------------
# Output variables:
check_docker_image_update() {
    log "check_docker_image_update: $1"
    detect_docker_registry_info $1
    detect_docker_image_tag $IMAGE_PATH_FULL $1
    get_local_docker_image_digest $IMAGE_LOCAL
    log "check_docker_image_update: DIGEST_LOCAL=${DIGEST_LOCAL}"

    if [ -z "${DIGEST_LOCAL}" ] ; then
        log "check_docker_image_update: Failed to get local digest $IMAGE_PATH"
        return 1
    fi

    get_remote_docker_image_digest "$IMAGE_PATH:latest"
    log "check_docker_image_update: DIGEST_REMOTE=${DIGEST_REMOTE}"

    if [ -z "${DIGEST_REMOTE}" ] ; then
        log "check_docker_image_update: Failed to get remote digest $IMAGE_PATH"
        return 1
    fi

    if [ "$DIGEST_LOCAL" != "$DIGEST_REMOTE" ] ; then
        $2 true "$IMAGE_PATH" "$VERSION_REMOTE"
    else
        $3 false "$IMAGE_PATH" "$VERSION_REMOTE"
    fi
}

# =====================================================================================
# get list of local images
# -------------------------------------------------------------------------------------
# Input variables:
# - None
# -------------------------------------------------------------------------------------
# Output variables:
LOCAL_IMAGES=""
get_docker_container_images() {
    log "get_docker_container_images"
    LOCAL_IMAGES=$(docker ps --format {{.Image}})
    log "get_docker_container_images: LOCAL_IMAGES=$LOCAL_IMAGES"
}

# =====================================================================================
# get list of local images
# -------------------------------------------------------------------------------------
# Input variables:
# - value, ex: true
# - container name, ex: nginx
# - version, ex: 1.27.2
# -------------------------------------------------------------------------------------
# Output variables:
send_data_to_influxdb() {
    log "send_data_to_influxdb: $1 $2 $3"
    local DATA_HOST=$(cat /etc/hostname)
    log "send_data_to_influxdb: DATA_HOST=$DATA_HOST"
    curl -i -XPOST "http://$INFLUX_HOST:$INFLUX_PORT/api/v2/write?org=$INFLUX_ORG&bucket=$INFLUX_BUCKET&precision=ns" \
        --header "Authorization: Token $INFLUX_TOKEN" \
        --data-raw "updates,type=docker,host=$DATA_HOST,container=$2,version=$3 value=$1 $(date +%s%N)"
}

# =====================================================================================
# add to cron job
# -------------------------------------------------------------------------------------
# Config
CRONJOB_SCHEDULE="00 01 * * *"
add_to_cronjob() {
    log "add_to_cronjob"
    local CRONJOB_COMMAND=".$(realpath "${BASH_SOURCE[0]}")"
    log "add_to_cronjob: CRON_COMMAND=$CRONJOB_COMMAND"
    local CRONJOB="$CRONJOB_SCHEDULE $CRONJOB_COMMAND"
    log "add_to_cronjob: CRONJOB=$CRONJOB"
    ( crontab -l | grep -v -F "$CRONJOB_COMMAND" || : ; echo "$CRONJOB" ) | crontab -
}

# =====================================================================================
# Script logic
# =====================================================================================

IMAGE_ABSOLUTE="$1"

check_requirements "curl docker jq"
set -e
add_to_cronjob
if [ -z $IMAGE_ABSOLUTE ] ; then
    get_docker_container_images
    IMAGE_ABSOLUTE=$LOCAL_IMAGES
fi
for IMAGE in $IMAGE_ABSOLUTE
do
    check_docker_image_update "$IMAGE" "send_data_to_influxdb" "send_data_to_influxdb"
done
