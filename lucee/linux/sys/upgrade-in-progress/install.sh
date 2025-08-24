#!/bin/bash

# One-shot installer to deploy the Upgrade-In-Progress toolkit into /opt/lucee/sys/...

# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash

# Optional env vars:
#   OWNER=kenricashe REPO=lucee-installer REF=master

# Example QA test of dev branch:
# REF=feature/upgrade-in-progress-apache curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/upgrade-in-progress-apache/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

OWNER=${OWNER:-kenricashe}
REPO=${REPO:-lucee-installer}
REF=${REF:-master}

TARBALL_URL="https://codeload.github.com/${OWNER}/${REPO}/tar.gz/refs/heads/${REF}"
TMPDIR=$(mktemp -d)

cleanup() {
	if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
		rm -rf "$TMPDIR"
	fi
}
trap cleanup EXIT

echo "Downloading ${OWNER}/${REPO}@${REF} ..."

# When extracting GitHub tarballs, the top directory will be named {repo}-{ref}
# where {ref} has '/' characters replaced with '-'
if ! curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMPDIR"; then
	echo "Error: Failed to download or extract tarball: $TARBALL_URL"
	exit 1
fi

# Find the subdirectory containing this toolset
# GitHub tarballs include a top-level directory named {repo}-{branch}
# where branch names with slashes are converted to hyphens
echo "Searching for upgrade-in-progress directory..."

# First, find the top-level directory (should be something like lucee-installer-feature-upgrade-in-progress-apache)
TOP_DIR=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
echo "Found top-level directory: $TOP_DIR"

# Now look for the upgrade-in-progress directory within that top-level directory
SUBDIR="$TOP_DIR/lucee/linux/sys/upgrade-in-progress"

if [ ! -d "$SUBDIR" ]; then
	# If direct path doesn't work, try a more general search
	SUBDIR=$(find "$TMPDIR" -type d -path "*/lucee/linux/sys/upgrade-in-progress" | head -n1)

	if [ -z "$SUBDIR" ]; then
		# Debug: Show the directory structure to help diagnose the issue
		echo "Directory structure in tarball:"
		find "$TMPDIR" -type d | sort
		
		echo "Error: Could not locate subdirectory lucee/linux/sys/upgrade-in-progress in the tarball"
		exit 1
	fi
fi

echo "Found upgrade-in-progress directory at: $SUBDIR"

# Run the deployment script from the extracted directory
if [ ! -x "$SUBDIR/deploy-to-opt-lucee-sys.sh" ]; then
	chmod +x "$SUBDIR/deploy-to-opt-lucee-sys.sh" 2>/dev/null || true
fi

"$SUBDIR/deploy-to-opt-lucee-sys.sh"
