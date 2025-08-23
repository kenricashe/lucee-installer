#!/bin/bash

# One-shot installer to deploy the Upgrade-In-Progress toolkit into /opt/lucee/sys/...
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
# Optional env vars:
#   OWNER=kenricashe REPO=lucee-installer REF=master

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
if ! curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMPDIR"; then
	echo "Error: Failed to download or extract tarball: $TARBALL_URL"
	exit 1
fi

# Find the subdirectory containing this toolset
SUBDIR=$(find "$TMPDIR" -type d -path "*/lucee/linux/sys/upgrade-in-progress" | head -n1)
if [ -z "$SUBDIR" ]; then
	echo "Error: Could not locate subdirectory lucee/linux/sys/upgrade-in-progress in the tarball"
	exit 1
fi

# Run the deployment script from the extracted directory
if [ ! -x "$SUBDIR/deploy-to-opt-lucee-sys.sh" ]; then
	chmod +x "$SUBDIR/deploy-to-opt-lucee-sys.sh" 2>/dev/null || true
fi

"$SUBDIR/deploy-to-opt-lucee-sys.sh"
