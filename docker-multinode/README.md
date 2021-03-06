Running Multi-Node Kubernetes Using Docker
------------------------------------------

_Note_:
These instructions are somewhat significantly more advanced than the [single node](http://kubernetes.io/docs/getting-started-guides/docker/) instructions. If you are interested in just starting to explore Kubernetes, we recommend that you start there.

**Table of Contents**

- [Prerequisites](#prerequisites)
- [Overview](#overview)
  - [Bootstrap Docker](#bootstrap-docker)
- [Master Node](#master-node)
- [Adding a worker node](#adding-a-worker-node)
- [Deploy a DNS](#deploy-a-dns)
- [Testing your cluster](#testing-your-cluster)

## Prerequisites

The only thing you need is a machine with **Docker 1.8.3 or higher**

## Overview

This guide will set up a 2-node Kubernetes cluster, consisting of a _master_ node which hosts the API server and orchestrates work
and a _worker_ node which receives work from the master. You can repeat the process of adding worker nodes an arbitrary number of
times to create larger clusters.

Here's a diagram of what the final result will look like:
![Kubernetes Single Node on Docker](k8s-docker.png)

### Bootstrap Docker

This guide also uses a pattern of running two instances of the Docker daemon
   1) A _bootstrap_ Docker instance which is used to start system daemons like `flanneld` and `etcd`
   2) A _main_ Docker instance which is used for the Kubernetes infrastructure and user's scheduled containers

This pattern is necessary because the `flannel` daemon is responsible for setting up and managing the network that interconnects
all of the Docker containers created by Kubernetes.  To achieve this, it must run outside of the _main_ Docker daemon.  However,
it is still useful to use containers for deployment and management, so we create a simpler _bootstrap_ daemon to achieve this.

You can specify the version on every node before install:

```sh
export K8S_VERSION=<your_k8s_version (e.g. 1.2.3)>
export ETCD_VERSION=<your_etcd_version (e.g. 2.2.5)>
export FLANNEL_VERSION=<your_flannel_version (e.g. 0.5.5)>
export FLANNEL_IPMASQ=<flannel_ipmasq_flag (defaults to true)>
```

Otherwise, we'll use latest `hyperkube` image as default k8s version.

## Master Node

The first step in the process is to initialize the master node.

The MASTER_IP step here is optional, it defaults to the first value of `hostname -I`.
Clone the `kube-deploy` repo, and run [master.sh](master.sh) on the master machine _with root_:

```console
$ export MASTER_IP=<your_master_ip (e.g. 1.2.3.4)>
$ cd docker-multinode
$ ./master.sh
```

`Master done!`

See [here](docker-multinode/master.md) for detailed instructions explanation.

## Adding a worker node

Once your master is up and running you can add one or more workers on different machines.

Clone the `kube-deploy` repo, and run [worker.sh](worker.sh) on the worker machine _with root_:

```console
$ export MASTER_IP=<your_master_ip (e.g. 1.2.3.4)>
$ cd docker-multinode
$ ./worker.sh
```

`Worker done!`

See [here](worker.md) for detailed instructions explanation.

## Deploy a DNS

See [here](deployDNS.md) for instructions.

## Testing your cluster

Once your cluster has been created you can [test it out](testing.md)

For more complete applications, please look at the [documentation](http://kubernetes.io/docs/samples/)
