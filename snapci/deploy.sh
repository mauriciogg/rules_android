#!/usr/bin/env bash

set -xeuo pipefail

export CI=true

source $(dirname $BASH_SOURCE)/utils.sh


tmp_dir=$(mktemp -d)
current_dir=$(pwd)
archive_path="${tmp_dir}/rules_android.tgz"

echo "Creating archive ${archive_path}"
pushd "${tmp_dir}"
tar -C "${current_dir}" --exclude='.[^/]*' -cvzf rules_android.tgz .
popd


echo "Getting commit SHA"
git_sha=$(git rev-parse --short HEAD) || exit 1

GCS_DIR_NAME="snapengine-maven-publish/bazel-releases/rules/rules_android/${BUILD_NUMBER}-${git_sha}/rules_android.tgz"
GCS_URL="gs://${GCS_DIR_NAME}"
HTTP_URL="https://storage.googleapis.com/${GCS_DIR_NAME}"

echo "Uploading rules_android to GCS..."
gsutil cp "${archive_path}" "$GCS_URL"

echo "Getting shasum of the binary"
sha256=$(shasum -a 256 "${archive_path}" | awk '{print $1}')

echo "Posting PR Comment..."
escaped_url=$(escape_sashes "${HTTP_URL}")
comment="Rules published:\r\n sha256 = ${sha256} \r\n url = ${escaped_url}"
post_comment "$comment"
