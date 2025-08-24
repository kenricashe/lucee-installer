#!/bin/bash

# One-shot installer to deploy the Upgrade-In-Progress toolkit into /opt/lucee/sys/...

# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
#
# To use a specific branch/ref:
#   curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/branch-name/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash -s feature/branch-name
#
# Example:
#   curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/upgrade-in-progress-apache/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash -s feature/upgrade-in-progress-apache

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Check for command line arguments first (highest priority)
if [ -n "$1" ]; then
	REF="$1"
	echo "Using REF=$REF from command line argument"
fi

# Extract the REF from the URL if it's not set
# This handles the case where REF is set before curl but not passed through sudo
if [ -z "$REF" ] && [ -n "$0" ] && [[ "$0" == *"/raw.githubusercontent.com/"* ]]; then
	URL_PATH="$0"
	REF_FROM_URL=$(echo "$URL_PATH" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
	if [ -n "$REF_FROM_URL" ]; then
		REF="$REF_FROM_URL"
		echo "Extracted REF=$REF from script URL"
	fi
fi

OWNER=${OWNER:-kenricashe}
REPO=${REPO:-lucee-installer}
REF=${REF:-master}

echo "Using: OWNER=$OWNER REPO=$REPO REF=$REF"

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

# Execute the deployment script and capture its exit status
if "$SUBDIR/deploy-to-opt-lucee-sys.sh"; then
	# Deployment was successful
	echo ""
	echo "=================================================================="
	echo "Deployment complete! The Upgrade-In-Progress toolkit is now installed."
	echo ""
	echo "To configure and manage upgrade mode, run:"
	echo "  sudo /opt/lucee/sys/upgrade-in-progress/menu.sh"
	echo "=================================================================="
else
	# Deployment failed
	DEPLOY_STATUS=$?
	echo ""
	echo "=================================================================="
	echo "ERROR: Deployment failed with exit code $DEPLOY_STATUS"
	echo "Please check the error messages above for more information."
	echo "=================================================================="
	exit $DEPLOY_STATUS
fi
