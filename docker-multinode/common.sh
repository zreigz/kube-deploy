#!/bin/bash

# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Utility functions for Kubernetes in docker setup

source $(dirname "${BASH_SOURCE}")/cni-plugin.sh
source $(dirname "${BASH_SOURCE}")/docker-bootstrap.sh

kube::multinode::main(){
  LATEST_STABLE_K8S_VERSION=$(kube::helpers::curl "https://storage.googleapis.com/kubernetes-release/release/stable.txt")
  K8S_VERSION=${K8S_VERSION:-${LATEST_STABLE_K8S_VERSION}}

  ETCD_VERSION=${ETCD_VERSION:-"2.2.5"}

  FLANNEL_VERSION=${FLANNEL_VERSION:-"0.5.5"}
  FLANNEL_IPMASQ=${FLANNEL_IPMASQ:-"true"}
  FLANNEL_BACKEND=${FLANNEL_BACKEND:-"udp"}
  FLANNEL_NETWORK=${FLANNEL_NETWORK:-"10.1.0.0/16"}

  RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}

  CURRENT_PLATFORM=$(kube::helpers::host_platform)
  ARCH=${ARCH:-${CURRENT_PLATFORM##*/}}

  DEFAULT_NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
  NET_INTERFACE=${NET_INTERFACE:-${DEFAULT_NET_INTERFACE}}

  TIMEOUT_FOR_SERVICES=${TIMEOUT_FOR_SERVICES:-20}
  USE_CNI=${USE_CNI:-"false"}
  CNI_ARGS=""

  # Constants
  BOOTSTRAP_DOCKER_SOCK="unix:///var/run/docker-bootstrap.sock"
  BOOTSTRAP_DOCKER_PARAM="-H ${BOOTSTRAP_DOCKER_SOCK}"
  KUBELET_MOUNTS="\
    -v /sys:/sys:rw \
    -v /var/run:/var/run:rw \
    -v /run:/run:rw \
    -v /var/lib/docker:/var/lib/docker:rw \
    -v /var/lib/kubelet:/var/lib/kubelet:shared \
    -v /var/log/containers:/var/log/containers:rw"

  # Paths
  FLANNEL_SUBNET_DIR=${FLANNEL_SUBNET_DIR:-/run/flannel}

  if [[ ${USE_CNI} == true ]]; then

    BOOTSTRAP_DOCKER_PARAM=""
    CNI_ARGS="\
      --network-plugin=cni \
      --network-plugin-dir=/etc/cni/net.d"
  fi

  # Trap errors
  kube::log::install_errexit
}

# Make shared kubelet directory
kube::multinode::make_shared_kubelet_dir() {
    mkdir -p /var/lib/kubelet
    mount --bind /var/lib/kubelet /var/lib/kubelet
    mount --make-shared /var/lib/kubelet
}

# Ensure everything is OK, docker is running and we're root
kube::multinode::check_params() {

  # Make sure docker daemon is running
  if [[ $(docker ps 2>&1 1>/dev/null; echo $?) != 0 ]]; then
    kube::log::error "Docker is not running on this machine!"
    exit 1
  fi

  # Require root
  if [[ "$(id -u)" != "0" ]]; then
    kube::log::error >&2 "Please run as root"
    exit 1
  fi

  kube::helpers::parse_version ${K8S_VERSION}

  # Output the value of the variables
  kube::log::status "K8S_VERSION is set to: ${K8S_VERSION}"
  kube::log::status "ETCD_VERSION is set to: ${ETCD_VERSION}"
  kube::log::status "FLANNEL_VERSION is set to: ${FLANNEL_VERSION}"
  kube::log::status "FLANNEL_IPMASQ is set to: ${FLANNEL_IPMASQ}"
  kube::log::status "FLANNEL_NETWORK is set to: ${FLANNEL_NETWORK}"
  kube::log::status "FLANNEL_BACKEND is set to: ${FLANNEL_BACKEND}"
  kube::log::status "RESTART_POLICY is set to: ${RESTART_POLICY}"
  kube::log::status "MASTER_IP is set to: ${MASTER_IP}"
  kube::log::status "ARCH is set to: ${ARCH}"
  kube::log::status "NET_INTERFACE is set to: ${NET_INTERFACE}"
  kube::log::status "USE_CNI is set to: ${USE_CNI}"
  kube::log::status "--------------------------------------------"
}

# Start etcd on the master node
kube::multinode::start_etcd() {

  kube::log::status "Launching etcd..."

  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --restart=${RESTART_POLICY} \
    --net=host \
    -v /var/lib/kubelet/etcd:/var/etcd \
    gcr.io/google_containers/etcd-${ARCH}:${ETCD_VERSION} \
    /usr/local/bin/etcd \
      --listen-client-urls=http://127.0.0.1:4001,http://${MASTER_IP}:4001 \
      --advertise-client-urls=http://${MASTER_IP}:4001 \
      --data-dir=/var/etcd/data

  # Wait for etcd to come up
  local SECONDS=0
  while [[ $(curl -fs http://localhost:4001/v2/machines 2>&1 1>/dev/null; echo $?) != 0 ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      kube::log::error "etcd failed to start. Exiting..."
      exit 1
    fi
    sleep 1
  done

  # Set flannel net config
  docker ${BOOTSTRAP_DOCKER_PARAM} run \
      --net=host \
      gcr.io/google_containers/etcd-${ARCH}:${ETCD_VERSION} \
      etcdctl \
      set /coreos.com/network/config \
          "{ \"Network\": \"${FLANNEL_NETWORK}\", \"Backend\": {\"Type\": \"${FLANNEL_BACKEND}\"}}"

  sleep 2
}

# Start flannel in docker bootstrap, both for master and worker
kube::multinode::start_flannel() {

  kube::log::status "Launching flannel..."

  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --restart=${RESTART_POLICY} \
    --net=host \
    --privileged \
    -v /dev/net:/dev/net \
    -v ${FLANNEL_SUBNET_DIR}:${FLANNEL_SUBNET_DIR} \
    gcr.io/google_containers/flannel-${ARCH}:${FLANNEL_VERSION} \
    /opt/bin/flanneld \
      --etcd-endpoints=http://${MASTER_IP}:4001 \
      --ip-masq="${FLANNEL_IPMASQ}" \
      --iface="${NET_INTERFACE}"

  # Wait for the flannel subnet.env file to be created instead of a timeout. This is faster and more reliable
  local SECONDS=0
  while [[ ! -f ${FLANNEL_SUBNET_DIR}/subnet.env ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      kube::log::error "flannel failed to start. Exiting..."
      exit 1
    fi
    sleep 1
  done

  source ${FLANNEL_SUBNET_DIR}/subnet.env

  kube::log::status "FLANNEL_SUBNET is set to: ${FLANNEL_SUBNET}"
  kube::log::status "FLANNEL_MTU is set to: ${FLANNEL_MTU}"
}

# Start kubelet first and then the master components as pods
kube::multinode::start_k8s_master() {
  kube::log::status "Launching Kubernetes master components..."

  kube::multinode::make_shared_kubelet_dir

  # TODO: Get rid of --hostname-override
  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    ${KUBELET_MOUNTS} \
    fest/hyperkube-amd64:v1.3.3 \
    /hyperkube kubelet \
      --allow-privileged \
      --api-servers=http://localhost:8080 \
      --config=/etc/kubernetes/manifests-multi \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      --hostname-override=$(ip -o -4 addr list ${NET_INTERFACE} | awk '{print $4}' | cut -d/ -f1) \
      --v=2
}

# Start kubelet in a container, for a worker node
kube::multinode::start_k8s_worker() {
  kube::log::status "Launching Kubernetes worker components..."

  kube::multinode::make_shared_kubelet_dir

  # TODO: Use secure port for communication
  # TODO: Get rid of --hostname-override
  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    ${KUBELET_MOUNTS} \
    fest/hyperkube-amd64:v1.3.3 \
    /hyperkube kubelet \
      --allow-privileged \
      --api-servers=http://${MASTER_IP}:8080 \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      --hostname-override=$(ip -o -4 addr list ${NET_INTERFACE} | awk '{print $4}' | cut -d/ -f1) \
      --v=2
}

# Start kube-proxy in a container, for a worker node
kube::multinode::start_k8s_worker_proxy() {

  # Some quite complex version checking here...
  # If the version is under v1.3.0-alpha.5, kube-proxy is run manually in this script
  # In v1.3.0-alpha.5 and above, kube-proxy is run in a DaemonSet
  # This has been uncommented for now, since the DaemonSet was inactivated in the stable v1.3 release
  #if [[ $((VERSION_MINOR < 3)) == 1 || \
  #      $((VERSION_MINOR <= 3)) == 1 && \
  #      $(echo ${VERSION_EXTRA}) != "" && \
  #      ${VERSION_PRERELEASE} == "alpha" && \
  #      $((VERSION_PRERELEASE_REV < 5)) == 1 ]]; then

  kube::log::status "Launching kube-proxy..."
  docker run -d \
    --net=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    gcr.io/google_containers/hyperkube-${ARCH}:${K8S_VERSION} \
    /hyperkube proxy \
        --master=http://${MASTER_IP}:8080 \
        --v=2
}

# Turndown the local cluster
kube::multinode::turndown(){

  # Check if docker bootstrap is running
  if [[ $(kube::helpers::is_running ${BOOTSTRAP_DOCKER_SOCK}) == "true" ]]; then

    kube::log::status "Killing docker bootstrap..."

    # Kill all docker bootstrap's containers
    if [[ $(docker -H ${BOOTSTRAP_DOCKER_SOCK} ps -q | wc -l) != 0 ]]; then
      docker -H ${BOOTSTRAP_DOCKER_SOCK} rm -f $(docker -H ${BOOTSTRAP_DOCKER_SOCK} ps -q)
    fi

    # Kill bootstrap docker
    kill $(ps aux | grep ${BOOTSTRAP_DOCKER_SOCK} | grep -v grep | awk '{print $2}')

  fi

  if [[ $(kube::helpers::is_running /hyperkube) == "true" ]]; then

    kube::log::status "Killing hyperkube containers..."

    # Kill all hyperkube docker images
    docker rm -f $(docker ps | grep gcr.io/google_containers/hyperkube | awk '{print $1}')
  fi

  if [[ $(kube::helpers::is_running /pause) == "true" ]]; then

    kube::log::status "Killing pause containers..."

    # Kill all pause docker images
    docker rm -f $(docker ps | grep gcr.io/google_containers/pause | awk '{print $1}')
  fi

  if [[ $(docker ps -q | wc -l) != 0 ]]; then
    read -p "Should we stop the other containers that are running too? [Y/n] " stop_containers

    case $stop_containers in
      [nN]*)
        ;; # Do nothing
      *)
        docker kill $(docker ps -q)
        ;;
    esac
  fi

  if [[ -d /var/lib/kubelet ]]; then
    read -p "Do you want to clean /var/lib/kubelet? [Y/n] " clean_kubelet_dir

    case $clean_kubelet_dir in
      [nN]*)
        ;; # Do nothing
      *)
        # umount if there are mounts in /var/lib/kubelet
        if [[ ! -z $(mount | grep /var/lib/kubelet | awk '{print $3}') ]]; then

          # The umount command may be a little bit subborn sometimes, so run the commands twice to ensure the mounts are gone
          mount | grep /var/lib/kubelet/* | awk '{print $3}' | xargs umount 1>/dev/null 2>/dev/null
          mount | grep /var/lib/kubelet/* | awk '{print $3}' | xargs umount 1>/dev/null 2>/dev/null
          umount /var/lib/kubelet 1>/dev/null 2>/dev/null
          umount /var/lib/kubelet 1>/dev/null 2>/dev/null
        fi

        # Delete the directory
        rm -rf /var/lib/kubelet
        ;;
    esac
  fi

}

# Install network utils: ifconfig, brctl
kube::multinode::install_network_utils() {
    if kube::helpers::command_exists yum; then

      if ! kube::helpers::command_exists ifconfig; then
        yum -y -q install net-tools
      fi
      if ! kube::helpers::command_exists brctl; then
        yum -y -q install bridge-utils
      fi

    elif kube::helpers::command_exists apt-get; then

      if ! kube::helpers::command_exists brctl; then
        apt-get install -y bridge-utils
      fi

    fi
}

## Helpers

# Check if a command is valid
kube::helpers::command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Usage: kube::helpers::file_replace_line {path_to_file} {value_to_search_for} {replace_that_line_with_this_content}
# Finds a line in a file and replaces the line with the third argument
kube::helpers::file_replace_line(){
  if [[ -z $(grep -e "$2" $1) ]]; then
    echo "$3" >> $1
  else
    sed -i "/$2/c\\$3" $1
  fi
}

kube::helpers::backup_file(){
  # Backup the current file
  cp -f ${1} ${1}.backup
}

# Check if a process is running
kube::helpers::is_running(){
  if [[ ! -z $(ps aux | grep ${1} | grep -v grep) ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Wraps curl or wget in a helper function.
# Output is redirected to stdout
kube::helpers::curl(){
  if [[ $(which curl 2>&1) ]]; then
    curl -sSL $1
  elif [[ $(which wget 2>&1) ]]; then
    wget -qO- $1
  else
    kube::log::error "Couldn't find curl or wget. Bailing out."
    exit 4
  fi
}

# This figures out the host platform without relying on golang. We need this as
# we don't want a golang install to be a prerequisite to building yet we need
# this info to figure out where the final binaries are placed.
kube::helpers::host_platform() {
  local host_os
  local host_arch
  case "$(uname -s)" in
    Linux)
      host_os=linux;;
    *)
      kube::log::error "Unsupported host OS. Must be linux."
      exit 1;;
  esac

  case "$(uname -m)" in
    x86_64*)
      host_arch=amd64;;
    i?86_64*)
      host_arch=amd64;;
    amd64*)
      host_arch=amd64;;
    aarch64*)
      host_arch=arm64;;
    arm64*)
      host_arch=arm64;;
    arm*)
      host_arch=arm;;
    ppc64le*)
      host_arch=ppc64le;;
    *)
      kube::log::error "Unsupported host arch. Must be x86_64, arm, arm64 or ppc64le."
      exit 1;;
  esac
  echo "${host_os}/${host_arch}"
}

kube::helpers::parse_version() {
  local -r version_regex="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(beta|alpha)\\.(0|[1-9][0-9]*))?$"
  local -r version="${1-}"
  [[ "${version}" =~ ${version_regex} ]] || {
    kube::log::error "Invalid release version: '${version}', must match regex ${version_regex}"
    return 1
  }
  VERSION_MAJOR="${BASH_REMATCH[1]}"
  VERSION_MINOR="${BASH_REMATCH[2]}"
  VERSION_PATCH="${BASH_REMATCH[3]}"
  VERSION_EXTRA="${BASH_REMATCH[4]}"
  VERSION_PRERELEASE="${BASH_REMATCH[5]}"
  VERSION_PRERELEASE_REV="${BASH_REMATCH[6]}"
}

# Print a status line. Formatted to show up in a stream of output.
kube::log::status() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "+++ $timestamp $1"
  shift
  for message; do
    echo "    $message"
  done
}

# Handler for when we exit automatically on an error.
# Borrowed from https://gist.github.com/ahendrix/7030300
kube::log::errexit() {
  local err="${PIPESTATUS[@]}"

  # If the shell we are in doesn't have errexit set (common in subshells) then
  # don't dump stacks.
  set +o | grep -qe "-o errexit" || return

  set +o xtrace
  local code="${1:-1}"
  kube::log::error_exit "'${BASH_COMMAND}' exited with status $err" "${1:-1}" 1
}

kube::log::install_errexit() {
  # trap ERR to provide an error handler whenever a command exits nonzero  this
  # is a more verbose version of set -o errexit
  trap 'kube::log::errexit' ERR

  # setting errtrace allows our ERR trap handler to be propagated to functions,
  # expansions and subshells
  set -o errtrace
}

# Print out the stack trace
#
# Args:
#   $1 The number of stack frames to skip when printing.
kube::log::stack() {
  local stack_skip=${1:-0}
  stack_skip=$((stack_skip + 1))
  if [[ ${#FUNCNAME[@]} -gt $stack_skip ]]; then
    echo "Call stack:" >&2
    local i
    for ((i=1 ; i <= ${#FUNCNAME[@]} - $stack_skip ; i++))
    do
      local frame_no=$((i - 1 + stack_skip))
      local source_file=${BASH_SOURCE[$frame_no]}
      local source_lineno=${BASH_LINENO[$((frame_no - 1))]}
      local funcname=${FUNCNAME[$frame_no]}
      echo "  $i: ${source_file}:${source_lineno} ${funcname}(...)" >&2
    done
  fi
}

# Log an error and exit.
# Args:
#   $1 Message to log with the error
#   $2 The error code to return
#   $3 The number of stack frames to skip when printing.
kube::log::error_exit() {
  local message="${1:-}"
  local code="${2:-1}"
  local stack_skip="${3:-0}"
  stack_skip=$((stack_skip + 1))

  local source_file=${BASH_SOURCE[$stack_skip]}
  local source_line=${BASH_LINENO[$((stack_skip - 1))]}
  echo "!!! Error in ${source_file}:${source_line}" >&2
  [[ -z ${1-} ]] || {
    echo "  ${1}" >&2
  }

  kube::log::stack $stack_skip

  echo "Exiting with status ${code}" >&2
  exit "${code}"
}

# Log an error but keep going.  Don't dump the stack or exit.
kube::log::error() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "!!! $timestamp ${1-}" >&2
  shift
  for message; do
    echo "    $message" >&2
  done
}
