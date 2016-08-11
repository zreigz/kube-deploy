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

# Install git and curl
install_minimal_dependencies() {
	apt-get install -y git curl
}

# Install docker
install_docker() {
	apt-get install -y apt-transport-https ca-certificates
	apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
	tee /etc/apt/sources.list.d/docker.list <<-'EOF'
deb https://apt.dockerproject.org/repo ubuntu-wily main
EOF
	apt-get update
	apt-get install -y -q docker-engine=1.10.3-0~wily
}

# Clone kubernetes/kube-deploy project
clone_kube_deploy() {
	git clone https://github.com/kubernetes/kube-deploy.git
}

# Clone kubernetes
clone_k8s() {
	git clone https://github.com/kubernetes/kubernetes.git
}

# Install and configure Go
install_go() {
	curl -L https://storage.googleapis.com/golang/go1.6.3.linux-amd64.tar.gz -o /tmp/go1.6.3.linux-amd64.tar.gz
	tar -C /usr/local -xzf /tmp/go1.6.3.linux-amd64.tar.gz
	rm /tmp/go1.6.3.linux-amd64.tar.gz
	export PATH=$PATH:/usr/local/go/bin
	export GOPATH=$HOME/go
	export PATH=$GOPATH/bin:$PATH
}

# Start e2e conformance tests
start_tests() {
	export KUBERNETES_PROVIDER=skeleton
  export GINKGO_PARALLEL=y
  export KUBERNETES_CONFORMANCE_TEST=y

	# Compile minimal number of packages to run tests
  cd /home/vagrant/kubernetes
  go get -u github.com/jteeuwen/go-bindata/go-bindata
  make all WHAT=cmd/kubectl
  make all WHAT=vendor/github.com/onsi/ginkgo/ginkgo
  make all WHAT=test/e2e/e2e.test

  # Configure kube config
  cluster/kubectl.sh config set-cluster local --server=http://${MASTER_IP}:8080 --insecure-skip-tls-verify=true
  cluster/kubectl.sh config set-context local --cluster=local
  cluster/kubectl.sh config use-context local

  # Run tests in parallel mode and detach the process.
  nohup go run hack/e2e.go --v --test -check_version_skew=false --test_args="--ginkgo.skip=\[Serial\]|\[Flaky\]|\[Feature:.+\]" > /home/vagrant/e2e.txt &
  echo "Tests started"
  sleep 1
}
