#!/usr/bin/env bash

set -xeuo pipefail

export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK=$ANDROID_HOME
export ANDROID_SDK_ROOT=$ANDROID_SDK

bash snapci/install_android_sdk.sh

export CI=true

# From kokoro/presubmit/kokoro_presubmit.sh
echo "Building and testing rules android..."
pushd examples/basicapp/
"bzl" build \
    --verbose_failures \
    --experimental_google_legacy_api \
    --experimental_enable_android_migration_apis \
    //java/com/basicapp:basic_app
popd 
