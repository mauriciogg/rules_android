#!/bin/bash
# This script is used for installing Android SDK tools from cached versions on GCS
# See README.md for more details.
#

EXECUTION_TYPE=${1:-}

# Fail on errors (unless it's warn only)
if [[ "$EXECUTION_TYPE" != "--warn-only" ]]; then
    set -euo pipefail
fi

set +x

CONFIG_FILE="$(dirname ${BASH_SOURCE:-$0})/android_sdk_config.json"
GCS_PREFIX="gs://snapengine-maven-publish/android-sdk-releases"
if [[ -n "${CI:-}" ]] || [[ -n "${VERBOSE:-}" ]]; then
    VERBOSE=1
else
    VERBOSE=
fi

# Read the initial config (not readonly because it can be modified during updating)
CONFIG=$(cat "$CONFIG_FILE")

# print the string as red
error() {
    if [[ -z $TERM ]]; then
        echo -e $@ >&2
    else
        echo -e "\033[0;31m$@\033[0m" >&2
    fi
    if [[ "$EXECUTION_TYPE" != "--warn-only" ]]; then
        exit 1
    fi
}

# print the string in bold
bold() {
    if [[ -z $TERM ]]; then
        echo -e $@
    else
        echo -e "\033[1m$@\033[0m"
    fi
}

function run_jq() {
    local JQ_VERSION="1.6"
    local jq_args=""
    if [ "$#" -gt 0 ]; then
        jq_args=$(printf " %q" "${@}")
    fi

    local jq_url_prefix="gs://snapengine-maven-publish/ci/jq/$JQ_VERSION"
    if [[ "$(uname)" == "Darwin" ]]; then
        local jq_bin="jq-osx-amd64"
        local jq_md5="wV+GrZKY7nHPfZain4boig=="
    else
        local jq_bin="jq-linux64"
        local jq_md5="H//enzx5RPBjJl6aXmeuTw=="
    fi
    local jq_url="$jq_url_prefix/$jq_bin"

    local jq="/tmp/$jq_bin-$JQ_VERSION-$jq_md5"
    if [ ! -x "$jq" ]; then
        gsutil -h Content-MD5:$jq_md5 cp $jq_url $jq
        chmod ugo+x $jq
    fi

    bash -c "$jq $jq_args"
}

# Install android sdk packages
function install_android_sdk() {
    if [[ -z "${ANDROID_HOME:-}" ]]; then
        error "ANDROID_HOME environment variable is not set"
    elif [[ -n "${VERBOSE}" ]]; then
        echo "Checking Android SDK installation: $(bold $ANDROID_HOME)"
    fi
    mkdir -p $ANDROID_HOME

    # Remove any trailing slashes
    local android_home="${ANDROID_HOME%/}"

    # Make sure ANDROID_SDK is set to the same value
    export ANDROID_SDK="$android_home"

    # Get the OS of the packages to install
    if [[ "$(uname)" == "Darwin" ]]; then
        local os="darwin"
    else
        local os="linux"
    fi

    # Check and install all packages if needed
    local packages=( $(echo "$CONFIG" | run_jq -rMc "keys_unsorted | .[]") )
    for package_index in "${packages[@]}"; do
        local package_config=( $(echo "$CONFIG" | run_jq --arg os $os -rMc ".[$package_index].package, .[$package_index].version, .[$package_index].version_key, .[$package_index].install_path, .[$package_index].files[\$os].md5") )
        local package_name=${package_config[@]:0:1}
        local package_version=${package_config[@]:1:1}
        local package_version_key=${package_config[@]:2:1}
        local package_install_path=${package_config[@]:3:1}
        local package_md5=${package_config[@]:4:1}

        # Determine the install directory for the package (use subdirectory from config if it's defined)
        if [[ "$package_install_path" == "null" ]]; then
            local package_install_directory="$android_home/$package_name/$package_version"
            # clear out any other invalid versions
            local installed_versions=( $(ls "$android_home/$package_name") )
            if [ ${#installed_versions[@]} -ne 0 ]; then
                for install_version in "${installed_versions[@]}"; do
                    if [[ ! -f "$android_home/$package_name/$install_version/source.properties" ]]; then
                        local install_directory="$android_home/$package_name/$install_version"
                        if [[ -n "${VERBOSE}" ]]; then
                            echo "Cleaning invalid package $(bold $install_directory)"
                        fi
                        rm -rf "$install_directory"
                    fi
                done
            fi
        else
            local package_install_directory="$android_home/$package_install_path"
        fi

        # Get the version of the currently installed package
        if [[ -f "$package_install_directory/source.properties" ]]; then
            local current_package_version=$(cat $package_install_directory/source.properties | grep --color=auto "^$package_version_key" | awk -F"=" '{print $2}' | xargs)
        else
            local current_package_version=""
        fi

        # Compare the current version to the expected version
        if [[ "$current_package_version" != "$package_version" ]]; then
            echo "Installing Android SDK $(bold $package_name) version $(bold $package_version)..."
            local download_url="${GCS_PREFIX}/$package_name/$package_version/$package_name-$package_version-$os.zip"
            local download_file="/tmp/$(basename $download_url)"
            echo "Downloading $(bold $download_url) to $(bold $download_file)..."
            gsutil -h Content-MD5:$package_md5 cp $download_url $download_file

            # Unzip and strip the first subdirectory
            rm -rf $package_install_directory
            mkdir -p $package_install_directory
            echo "Unzipping $(bold $download_file) into $(bold $package_install_directory)..."
            local temp=$(mktemp -d)
            unzip -o $download_file -d $temp
            mv "$temp"/*/* "$package_install_directory"

            # Clean up
            rmdir "$temp"/* "$temp"
            rm -rf $download_file
        elif [[ -n "${VERBOSE}" ]]; then
            echo "Skiped installing Android SDK $(bold $package_name) version $(bold $package_version). Already installed."
        fi

        # Expose install paths for all sdk components as env variables
        # Examples:
        #   ANDROID_NDK=...
        #   ANDROID_NDK_HOME=...
        local package_name_uppercase=$(echo $package_name | awk '{print toupper($0)}')
        export ANDROID_${package_name_uppercase//-/_}=$package_install_directory
        export ANDROID_${package_name_uppercase//-/_}_HOME=$package_install_directory
    done

    # Accept Android SDK License Agreements
    if ! grep --color=auto -q "24333f8a63b6825ea9c5514f83c2829b004d1fee" "$android_home/licenses/android-sdk-license"; then
        echo "Accepting Android SDK licenses..."
        (yes | $android_home/cmdline-tools/latest/bin/sdkmanager --licenses) || true
        # Above command can sometimes fail to accept liceses. https://partnerissuetracker.corp.google.com/issues/123054726
        # Below is a temp solution until the issue is fixed.
        echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" >> "$android_home/licenses/android-sdk-license"
    fi

    # Done!
    if [ -n "${VERBOSE}" ]; then
        echo $(bold "Android SDK installation was completed successfully.")
    fi
}

# initialize jq
run_jq --version >/dev/null

install_android_sdk
