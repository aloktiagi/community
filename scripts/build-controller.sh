#!/usr/bin/env bash

# A script that builds a single ACK service controllers an AWS API

set -Eou pipefail

SOURCE_REPO=github.com/aws/aws-controllers-k8s
SCRIPTS_DIR=$(cd "$(dirname "$0")"; pwd)
BIN_DIR=$SCRIPTS_DIR/../bin
TEMPLATES_DIR=$SCRIPTS_DIR/../templates

source "$SCRIPTS_DIR"/lib/common.sh
source "$SCRIPTS_DIR"/lib/k8s.sh

: "${ACK_GENERATE_CACHE_DIR:=~/.cache/aws-controllers-k8s}"
: "${ACK_GENERATE_BIN_PATH:=$BIN_DIR/ack-generate}"
: "${ACK_GENERATE_API_VERSION:="v1alpha1"}"
: "${ACK_GENERATE_CONFIG_PATH:=""}"

USAGE="
Usage:
  $(basename "$0") <service>

<service> should be an AWS service API aliases that you wish to build -- e.g.
's3' 'sns' or 'sqs'

Environment variables:
  ACK_GENERATE_CACHE_DIR    Overrides the directory used for caching AWS API
                            models used by the ack-generate tool.
                            Default: $ACK_GENERATE_CACHE_DIR
  ACK_GENERATE_BIN_PATH:    Overrides the path to the the ack-generate binary.
                            Default: $ACK_GENERATE_BIN_PATH
  ACK_GENERATE_API_VERSION: Overrides the version of the Kubernetes API objects
                            generated by the ack-generate apis command. If not
                            specified, and the service controller has been
                            previously generated, the latest generated API
                            version is used. If the service controller has yet
                            to be generated, 'v1alpha1' is used.
  ACK_GENERATE_CONFIG_PATH: Specify a path to the generator config YAML file to
                            instruct the code generator for the service.
                            Default: services/{SERVICE}/generator.yaml
"

if [ $# -ne 1 ]; then
    echo "ERROR: $(basename "$0") only accepts a single parameter" 1>&2
    echo "$USAGE"
    exit 1
fi

ensure_controller_gen

if [ ! -f $ACK_GENERATE_BIN_PATH ]; then
    if is_installed "ack-generate"; then
        ACK_GENERATE_BIN_PATH=$(which "ack-generate")
    else
        echo "ERROR: Unable to find an ack-generate binary.
Either set the ACK_GENERATE_BIN_PATH to a valid location,
run:
 
   make build-ack-generate
 
from the root directory or install ack-generate using:

   go get -u github.com/aws/aws-controllers-k8s/cmd/ack-generate" 1>&2
        exit 1;
    fi
fi

SERVICE="$1"

# If there's a generator.yaml in the service's directory and the caller hasn't
# specified an override, use that.
if [ -n "$ACK_GENERATE_CONFIG_PATH" ]; then
    if [ -f "services/$SERVICE/generator.yaml" ]; then
        ACK_GENERATE_CONFIG_PATH="services/$SERVICE/generator.yaml"
    fi
fi

ag_args="$SERVICE"
if [ -n "$ACK_GENERATE_CACHE_DIR" ]; then
    ag_args="$ag_args --cache-dir $ACK_GENERATE_CACHE_DIR"
fi

apis_args="apis $ag_args"
if [ -n "$ACK_GENERATE_API_VERSION" ]; then
    apis_args="$apis_args --version $ACK_GENERATE_API_VERSION"
fi

if [ -n "$ACK_GENERATE_CONFIG_PATH" ]; then
    ag_args="$ag_args --generator-config-path $ACK_GENERATE_CONFIG_PATH"
    apis_args="$apis_args --generator-config-path $ACK_GENERATE_CONFIG_PATH"
fi

echo "Building Kubernetes API objects for $SERVICE"
$ACK_GENERATE_BIN_PATH $apis_args
if [ $? -ne 0 ]; then
    exit 2
fi

echo "Generating deepcopy code for $SERVICE"
pushd services/$SERVICE/apis/$ACK_GENERATE_API_VERSION 1>/dev/null
controller-gen object:headerFile=$TEMPLATES_DIR/boilerplate.txt paths=./...
popd 1>/dev/null

echo "Generating custom resource definitions for $SERVICE"
pushd services/$SERVICE/apis/$ACK_GENERATE_API_VERSION 1>/dev/null
# Latest version of controller-gen (master) is required for following two reasons
# a) support for pointer values in map https://github.com/kubernetes-sigs/controller-tools/pull/317
# b) support for float type (allowDangerousTypes) https://github.com/kubernetes-sigs/controller-tools/pull/449
controller-gen crd:allowDangerousTypes=true paths=./...
popd 1>/dev/null

echo "Building service controller for $SERVICE"
controller_args="controller $ag_args"
$ACK_GENERATE_BIN_PATH $controller_args
if [ $? -ne 0 ]; then
    exit 2
fi