#!/bin/bash

set -o errexit

files_url='https://files.balena-cloud.com' # URL exporting S3 XML
s3_xml=$(curl -L -s $files_url)

# From https://stackoverflow.com/a/7052168
read_dom () {
    local IFS=\>
    read -d \< ENTITY CONTENT
}
s3_bucket=$(while read_dom; do if [[ $ENTITY = "Name" ]] ; then  echo $CONTENT; fi; done <<<"$s3_xml")

# Output arguments to stderr.
function err()
{
	echo "$@">&2
}

# Output arguments to stderr and halt with non-zero exit code.
function fatal()
{
	err "$@"
	exit 1
}

# Output usage and halt.
function usage() {
    cat <<EOUSAGE
usage: $0 [build|list] [options]

commands:
  list: list available devices and versions.
  build: build kernel module for specified device and OS versions.

build options:
  --device="$device"    Balena machine name.
  --os-version="$os-version"   Space separated list of OS versions.
  --src="$src"     Where to find kernel module source.
  --dest-dir="$output_dir"     Destination directory, defaults to "output".
  --modules-list="$modules_list"   Space separated list of modules to build.
  --linux-src="$linux_src"     Where to find linux kernel source for respective OS version.

EOUSAGE
}

function push()
{
	pushd $1 >/dev/null
}

function pop()
{
	popd >/dev/null
}

# Retrieves all available kernel header archives.
# args: $1 - device search pattern (default .*)
#       $2 - version search pattern (default .*)
function get_header_paths()
{
	local dev_pat="${1:-.*}"
	local ver_pat="${2:-.*}"
	list_kernels=$(aws s3api list-objects --no-sign-request --bucket $s3_bucket  --output text  --query 'Contents[]|[?contains(Key, `kernel`)]' | cut -f2)

	while read -r line; do
		if echo "$line" | grep -e "^\(esr\-\)\?images\/" | grep -q "$dev_pat/$ver_pat"; then
			device=$(echo "$line" | cut -f2 -d/)
			version=$(echo "$line" | cut -f3 -d/)
			echo "$line"
		# else
		# 	err "Could not find headers for '$device' at version '$version', run $0 list"
		fi
	done <<< "$list_kernels"
}

# List available devices and versions.
function list_versions()
{
	list_kernels=$(aws s3api list-objects --no-sign-request --bucket $s3_bucket  --output text  --query 'Contents[]|[?contains(Key, `kernel`)]|[?contains(Key,`images`)]' | cut -f2)

	while read -r line; do
		var1=$(echo "$line" | cut -f1 -d/)
		device=$(echo "$line" | cut -f2 -d/)
		version=$(echo "$line" | cut -f3 -d/)
		printf "%-30s %-30s\n" "$device" "$version"
	done <<< "$list_kernels"
}

# Retrieve kernel module headers from the specified remote path and build kernel
# module against them, generating a new copy of the kernel module with
# ..._<device>_<version> suffix.
function get_and_build()
{
	local path="$1"
	local modules="$2"
	local pattern="^(esr-)?images/(.*)/(.*)/"
	[[ "$path" =~ $pattern ]] || fatal "Invalid path '$path'?!"

	local device="${BASH_REMATCH[2]}"
	local version="${BASH_REMATCH[3]}"
	local output_dir="${output_dir}/modules_${device}_${version}"

	filename=$(basename $path)
	url="$files_url/$path"

	tmp_path=$(mktemp --directory)
	push $tmp_path

	if ! wget $(echo "$url" | sed -e 's/+/%2B/g'); then
		pop
		rm -rf "$tmp_path"

		err "ERROR: $path: Could not retrieve $url, skipping."
		didFail=1
		failedVersions+=" $version"
		return
	fi

	strip_depth=1
	if [[ $filename == *"source"* ]]; then
		# The kernel source tarball generated using kernel-devsrc pre-thud and post-thud have different folder layouts.
		# Detect the layout and select strip_depth accordingly
		test_strip=$(tar tzf $filename | head -2 | tail -1 | sed  's/[^0-9]*//g')
		if [ -z "$test_strip" ]; then
			strip_depth=2
		else
			strip_depth=3
		fi
		# Change output_dir to avoid overwriting the modules compiled from just the headers tarball
		output_dir="${output_dir}_from_src"
	fi

	if ! tar -xf $filename --strip $strip_depth; then
		pop
		rm -rf "$tmp_path"

		err "ERROR: $path: Unable to extract $tmp_path/$filename, skipping."
		didFail=1
		failedVersions+=" $version"
		return
	fi

	# Kernel headers for some devices need a few workarounds to build. These workarounds either effect
	# the build environment. Or the headers were incorrectly generated during the os build stage.
	# The full kernel source tarball available from v2.30+ should always work.
	/usr/local/bin/workarounds.sh $device $version $output_dir

	# find kernel version of source
	kernel_version=$(grep "Kernel Configuration" .config | cut -f3 -d" ")
	
	# get corresponding kernel source code
	linux_src_path="/usr/src/linux_${kernel_version}"
	if [[ ! -d $linux_src_path ]]; then
		# only clone is source doesn't exists
		git clone --depth 1 --branch v$kernel_version $kernel_git_source $linux_src_path
		else 
			echo "Kernel source exists for v:$kernel_version"
	fi

	make oldconfig
	
	for module in $modules_list;do
		echo "enabling module: $module" 
		./scripts/config --set-val CONFIG_$module m
	done
	make -C "$tmp_path" prepare
	make -C "$tmp_path" modules_prepare


	pop

	# Now create a copy of the module directory.
	rm -rf "$output_dir"/"$module_dir"
	mkdir -p "$output_dir"/"$module_dir"

	cp -R "$linux_src_path"/"$module_dir"/* "$output_dir"/"$module_dir"

	push "$output_dir"
 
	make -C "$tmp_path" M="$PWD"/"$module_dir" modules
	pop

	rm -rf "$tmp_path"
}

# Args handling
opts="$(getopt -o 'h?' --long 'list,device:,os-version:,src:,dest-dir:,modules-list:' -- "$@" || { usage >&2 && exit 1; })"
eval set -- "$opts"

device=
versions=
module_dir=
modules_list=
output_dir="output"
default_kernel_git="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/"
kernel_git_source="${KERNEL_GIT_SOURCE:-$default_kernel_git}"

while true; do
    flag=$1
    shift
    case "$flag" in
        --device) device="$1" && shift ;;
		--os-version) versions="$1" && shift ;;
		--dest-dir) output_dir="$1" && shift ;;
        --src) module_dir="$1" && shift ;;
        # --linux-src) linux_src="$1" && shift ;;
        --modules-list) modules_list="$1" && shift ;;
        --) break ;;
        *)
            {
                echo "error: unknown flag: $flag"
                usage
            } >&2
            exit 1
            ;;
    esac
done

# which command
command="$1"
case "$command" in
	build)
		shift
		;;
	list)
		echo "Fetching list from servers" && list_versions && exit
		;;
	*)
		{
			echo "error: unknown command: $1"
			usage
		} >&2
		exit 1
		;;
esac

[[ -z "$versions" ]] && fatal "ERROR: No version specified"
[[ -z "$module_dir" ]] && fatal "ERROR: No path for kernel module source specified"
[[ -z "$modules_list" ]] && fatal "ERROR: No modules specified"


if [[ -z "$device" ]]; then
	if [[ -z "$BALENA_MACHINE_NAME" ]]; then
		fatal "ERROR: No device specified"
	else
		err "No device specified, use default device type: $BALENA_MACHINE_NAME."
		device="$BALENA_MACHINE_NAME"
	fi
fi



didFail=
failedVersions=""

for version in $versions; do
	for path in $(get_header_paths "$device" "$version"); do
		if [[ $path == *"source"* ]]; then
			echo $path
			echo "Building $path..."

			get_and_build $path
		fi
	done
done


if [[ ! -z "$didFail" ]]; then
	fatal "Could not find headers for '$device' at version '$failedVersions', run $0 list"
fi

