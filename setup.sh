#!/bin/bash

# ---------------------------------
# Script Name: setup.sh
# Description: This script automates the setup of Talos on Turing Pi nodes, including downloading images, installing nodes, and configuring Kubernetes.
# Usage: ./setup.sh [options]
# Author: Yves Wetter
# License: MIT
# ---------------------------------

# Variables
LOG_FILE="setup.log"
DEFAULT_NODES="all"
IMAGE_DIR="images"
K8S_DIR="config"
TEMPLATE_DIR="templates"
BASE_IMAGE="Talos"
TALOS_VERSION="v1.8.3"
FIRMWARE_URL="https://github.com/nberlee/talos/releases/download/$TALOS_VERSION/metal-arm64.raw.xz"
TALOS_NODES=("node01.k8s.local" "node02.k8s.local" "node03.k8s.local" "node04.k8s.local")
TALOS_ROLES=("controlplane" "controlplane" "worker" "worker")
TALOS_CLUSTERNAME="turingpi"
TALOS_VIP="192.168.40.4"
TALOS_INSTALLER="ghcr.io/cloud-native-engineering/sem04_setup/installer-arm64:v1.8.3"

# ---------------------------------

# Function to display help
display_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --download            Download images from internet"
    echo "  -i, --install             Install node"
    echo "  -k, --k8s                 Configure Kubernetes"
    echo "  -n, --node [1,2,3,4]      Specify which node (default: all)"
    echo "  -h, --help                Display this help message"
}

# Function to log messages with timestamp and log level
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to ensure the image directory exists
ensure_image_dir() {
    if [[ ! -d "$IMAGE_DIR" ]]; then
        log "INFO" "Creating image directory: $IMAGE_DIR"
        mkdir -p "$IMAGE_DIR"
    fi
}

# Function to ensure the k8s directory exists
ensure_k8s_dir() {
    if [[ ! -d "$K8S_DIR" ]]; then
        log "INFO" "Creating k8s directory: $K8S_DIR"
        mkdir -p "$K8S_DIR"
    else
        log "WARN" "k8s directory already exists"
        log "WARN" "Backup existing k8s directory: $K8S_DIR"
        mv "$K8S_DIR" "$K8S_DIR-$(date +"%Y%m%d%H%M%S")"
        log "WARN" "removing existing k8s directory: $K8S_DIR"
        rm -rf "$K8S_DIR"
        log "INFO" "Creating k8s directory: $K8S_DIR"
        mkdir -p "$K8S_DIR"
    fi
}

# Function to download images from the internet
download_images() {
    ensure_image_dir
    log "INFO" "Downloading images from $FIRMWARE_URL"
    curl -L -o "$IMAGE_DIR/metal-arm64.raw.xz" "$FIRMWARE_URL"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to download images from $FIRMWARE_URL"
        exit 1
    fi
    log "INFO" "Successfully downloaded images"
    log "INFO" "Decompressing image file"
    xz -d "$IMAGE_DIR/metal-arm64.raw.xz"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to decompress image file"
        exit 1
    fi
    log "INFO" "Successfully decompressed image file"
}

# Function to install node
install() {
    log "INFO" "start installing Talos"
    if [[ "$nodes" == "$DEFAULT_NODES" ]]; then
        log "INFO" "Selected all nodes"
        log "INFO" "Shutting down all nodes"
        tpi power off
        for node in {1..4}; do
            log "INFO" "Installing node $node"
            tpi flash -i "$IMAGE_DIR/metal-arm64.raw" -n "$node"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to install node $node"
            else
                log "INFO" "Finished installing node $node"
                log "INFO" "Powering on node $node"
                tpi power on -n "$node"
            fi
        done
        log "INFO" "Finished installing all nodes"
    else
        validate_nodes "$nodes"
        node_index=$((nodes - 1))
        log "INFO" "Shutting down node $nodes"
        tpi power off -n "$nodes"
        log "INFO" "Installing node $nodes"
        tpi flash -i "$IMAGE_DIR/metal-arm64.raw" -n "$nodes"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to install node $nodes"
        else
            log "INFO" "Finished installing node $nodes"
            log "INFO" "Powering on node $node"
            tpi power on -n "$nodes"
        fi
    fi
}

# Function to configure k8s
k8s() {
    log "INFO" "start configure k8s"

    if [[ "$nodes" == "$DEFAULT_NODES" ]]; then
        ensure_k8s_dir
        log "INFO" "Generating $K8S_DIR/secrets.yaml"
        talosctl gen secrets --output-file "$K8S_DIR/secrets.yaml"
        log "INFO" "Configuring k8s on all nodes"
        log "INFO" "Generating general cluster config"
        talosctl gen config $TALOS_CLUSTERNAME https://$TALOS_VIP:6443 \
            --with-secrets "$K8S_DIR/secrets.yaml" \
            --config-patch-control-plane @"$TEMPLATE_DIR/controlplane-patch.yaml" \
            --config-patch-worker @"$TEMPLATE_DIR/worker-patch.yaml" \
            --output "$K8S_DIR" \
            --force
        for node in 0 1 2 3; do
            log "INFO" "Generating config for ${TALOS_ROLES[@]:$node:1} ${TALOS_NODES[@]:$node:1}..."
            talosctl machineconfig patch "$K8S_DIR/${TALOS_ROLES[@]:$node:1}.yaml" \
                --patch '[{"op": "add", "path": "/machine/network/hostname", "value": "'${TALOS_NODES[@]:$node:1}'"}]' \
                --talosconfig ./talosconfig \
                > "$K8S_DIR/${TALOS_NODES[@]:$node:1}.yaml"
        done
        for node in 0 1 2 3; do
            log "INFO" "Waiting for node #$((node+1)) to be ready..."
            until nc -zw 3 ${TALOS_NODES[@]:$node:1} 50000; do sleep 3; log "INFO" "Waiting..."; done
            log "INFO" "Applying config ${TALOS_NODES[@]:$node:1} to ${TALOS_ROLES[@]:$node:1}"
            talosctl apply config \
                --file "$K8S_DIR/${TALOS_NODES[@]:$node:1}.yaml" \
                --nodes ${TALOS_NODES[@]:$node:1} \
                --insecure
        done

        if [ -f ~/.talos/config ]; then
            log "INFO" "Remove old Talos config for ${TALOS_CLUSTERNAME}"
            yq -i e "del(.contexts.${TALOS_CLUSTERNAME})" ~/.talos/config
        fi
        log "INFO" "Merge Talos config for ${TALOS_CLUSTERNAME}"
        talosctl config merge ./$K8S_DIR/talosconfig --nodes $(echo ${TALOS_NODES[@]} | tr ' ' ',')
        yq -i e ".contexts.${TALOS_CLUSTERNAME}.endpoints += [\"${TALOS_NODES[@]:0:1}\"]" ~/.talos/config
        yq -i e ".contexts.${TALOS_CLUSTERNAME}.endpoints -= [\"127.0.0.1\"]" ~/.talos/config

        wait_for_all_talos_nodes

        log "INFO" "Bootstrapping Kubernetes at ${TALOS_NODES[@]:0:1}"
        talosctl bootstrap --nodes ${TALOS_NODES[@]:0:1}

        log "INFO" "Creating kubeconfig"
        yq -i e ".contexts.${TALOS_CLUSTERNAME}.endpoints += [\"${TALOS_VIP}\"]" ~/.talos/config
        yq -i e ".contexts.${TALOS_CLUSTERNAME}.endpoints -= [\"${TALOS_NODES[@]:0:1}\"]" ~/.talos/config

        if [ -f ~/.kube/config ]; then
            log "INFO" "Remove old Kubernetes context config for ${TALOS_CLUSTERNAME}"
            yq -i e "del(.clusters[] | select(.name == \"${TALOS_CLUSTERNAME}\"))" ~/.kube/config
            yq -i e "del(.users[] | select(.name == \"admin@${TALOS_CLUSTERNAME}\"))" ~/.kube/config
            yq -i e "del(.contexts[] | select(.name == \"admin@${TALOS_CLUSTERNAME}\"))" ~/.kube/config
        fi
        talosctl kubeconfig --nodes ${TALOS_NODES[@]:0:1}

        kubectl wait nodes --for condition=Ready --all --timeout 5m0s

        log "INFO" "Kubernetes is ready!"
        for node in 0 1 2 3; do
            log "INFO" "Upgrading ${TALOS_NODES[@]:$node:1} with extensions from ${INSTALLER}..."
            talosctl upgrade \
                    --image ${TALOS_INSTALLER} \
                    --nodes ${TALOS_NODES[@]:$node:1} \
                    --timeout 3m0s \
                    --force
        done
        wait_for_all_talos_nodes
        log "INFO" "All nodes are ready with Kubernetes!"
    else
        if [ ! -d $K8S_DIR ]; then
            log "ERROR" "No k8s directory found. Please run the script with --k8s option first."
            exit 1
        else
            validate_nodes "$nodes"
            node_index=$((nodes - 1))
            log "INFO" "Configuring k8s on node $nodes with role ${TALOS_ROLES[@]:$node_index:1}"
            talosctl apply config \
                --file "$K8S_DIR/${TALOS_NODES[@]:$node_index:1}.yaml" \
                --nodes ${TALOS_NODES[@]:$node_index:1} \
                --insecure
            until nc -zw 3 ${TALOS_NODES[@]:$node_index:1} 50000; do sleep 3; log "INFO" "Waiting..."; done
            log "INFO" "Upgrading ${TALOS_NODES[@]:$node:1} with extensions from ${INSTALLER}..."
            talosctl upgrade \
                --image ${TALOS_INSTALLER} \
                --nodes ${TALOS_NODES[@]:$node_index:1} \
                --timeout 3m0s \
                --force
            log "INFO" "Waiting for node $nodes to be ready"
            until nc -zw 3 ${TALOS_NODES[@]:$node_index:1} 50000; do sleep 3; log "INFO" "Waiting..."; done
            log "INFO" "Node ${HOSTNAMES[@]:$node:1} is ready!"
        fi
    fi
}

# Function to validate node selection
validate_nodes() {
    local nodes=$1
    if [[ ! "$nodes" =~ ^[1-4]$ ]]; then
        log "ERROR" "Invalid node selection: $nodes. Allowed values are a single number from 1 to 4."
        display_help
        exit 1
    fi
}

wait_for_all_talos_nodes() {
    for node in 0 1 2 3; do
        until nc -zw 3 ${TALOS_NODES[@]:$node:1} 50000; do sleep 3; printf '.'; done
        log "INFO" "Node ${HOSTNAMES[@]:$node:1} is ready!"
    done
}

# Function to prompt for confirmation
confirm() {
    read -r -p "${1:-Are you sure you want to proceed? [y/N]} " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

# ---------------------------------

main() {
    if [[ "$#" -eq 0 ]]; then
        display_help
        exit 0
    fi

    nodes="$DEFAULT_NODES"
    download_flag=false
    install_flag=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -d|--download) download_flag=true ;;
            -i|--install) install_flag=true ;;
            -k|--k8s) k8s_flag=true ;;
            -n|--node) shift; nodes="$1" ;;
            -h|--help) display_help; exit 0 ;;
            *) log "ERROR" "Unknown parameter passed: $1"; display_help; exit 1 ;;
        esac
        shift
    done

    if ! confirm "Are you sure you want to proceed with the selected options? [y/N]"; then
        log "INFO" "Operation cancelled by user."
        exit 0
    fi

    if [[ "$download_flag" == true ]]; then
        download_images
    fi

    if [[ "$install_flag" == true ]]; then
        install
    fi

    if [[ "$k8s_flag" == true ]]; then
        k8s
    fi

    if [[ "$download_flag" == false && "$install_flag" == false && "$k8s_flag" == false ]]; then
        log "ERROR" "At least one of --download, --install or --k8s must be used."
        display_help
        exit 1
    fi
}

main "$@"
