#!/bin/bash

# One-shot installer to deploy the Upgrade-In-Progress toolkit into /opt/lucee/sys/...

# Usage:
# curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
#
# Example with custom Lucee root path in environment variable:
# sudo LUCEE_ROOT=/opt/lucee6 bash -c 'curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/master/lucee/linux/sys/upgrade-in-progress/install.sh | bash'
#
# Example with non-master branch name in URL e.g. for QA testing:
# curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/upgrade-in-progress-apache/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
#
# GitHub CDN caching can last 5 minutes. For quicker testing, in the URL replace branch with the commit sha:
# curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/<commit-sha>/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
#
# Intentional branch mismatch should warn and exit:
# sudo REF=oopsie bash -c 'curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/feature/upgrade-in-progress-apache/lucee/linux/sys/upgrade-in-progress/install.sh | bash'

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1
fi

OWNER=${OWNER:-kenricashe}
REPO=${REPO:-lucee-installer}

# Auto-derive REF from the invoking raw.githubusercontent.com URL (curl | bash) when not provided
if [ -z "$REF" ]; then
	URL_REF_AUTO=""
	for PID in "$PPID" "$$"; do
		if [ -r "/proc/$PID/cmdline" ]; then
			CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
			if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]]; then
				URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
				if [ -n "$URL_REF_AUTO" ]; then
					break
				fi
			fi
		fi
	done
	if [ -n "$URL_REF_AUTO" ]; then
		REF="$URL_REF_AUTO"
		echo "Auto-detected REF=$REF from installer URL"
	fi
fi
REF=${REF:-master}

echo ""
echo "Using: OWNER=$OWNER REPO=$REPO REF=$REF"

# Detect mismatch between REF and the branch referenced in the installer URL (if available)
SCRIPT_REF=""
for PID in "$PPID" "$$"; do
	if [ -r "/proc/$PID/cmdline" ]; then
		CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
		if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]]; then
			SCRIPT_REF=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
			if [ -n "$SCRIPT_REF" ]; then
				break
			fi
		fi
	fi
done

if [ -n "$SCRIPT_REF" ] && [ "$REF" != "$SCRIPT_REF" ]; then
	echo ""
	echo "WARNING: REF is '$REF' but installer URL branch appears to be '$SCRIPT_REF'."
	echo ""
	echo "This mismatch can cause a 404 when downloading the tarball."
	echo ""
	echo "Please set REF=$SCRIPT_REF or use an installer URL that points to the '$REF' branch."
	echo ""
	exit 1
fi

TARBALL_URL="https://codeload.github.com/${OWNER}/${REPO}/tar.gz/${REF}"
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
# GitHub tarballs include a top-level directory named {repo}-{ref}
# where branch refs with slashes are converted to hyphens
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

# Check for Lucee root path from environment variable first
DEFAULT_LUCEE_ROOT="/opt/lucee"

if [ -n "$LUCEE_ROOT" ]; then
	# Environment variable provided
	echo "Using LUCEE_ROOT from environment: $LUCEE_ROOT"
elif [ -t 0 ]; then
	# Interactive mode - prompt for Lucee root path
	read -r -p "Enter target Lucee root path [${DEFAULT_LUCEE_ROOT}]: " INPUT_LUCEE_ROOT
	LUCEE_ROOT="${INPUT_LUCEE_ROOT:-$DEFAULT_LUCEE_ROOT}"
else
	# Non-interactive mode (curl pipe) - use default and continue
	LUCEE_ROOT="$DEFAULT_LUCEE_ROOT"
	echo "Using default Lucee root path: $LUCEE_ROOT"
fi

# Execute the deployment script and capture its exit status
if "$SUBDIR/deploy-to-opt-lucee-sys.sh" "$LUCEE_ROOT"; then
	# Deployment was successful
	echo ""
	echo "=================================================================="
	echo "Deployment complete! The Upgrade-In-Progress toolkit is now installed."
	echo ""
	echo "To configure and manage upgrade mode, run:"
	echo "  sudo ${LUCEE_ROOT}/sys/upgrade-in-progress/menu.sh"
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
