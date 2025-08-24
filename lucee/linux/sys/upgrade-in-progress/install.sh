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

# Optional: allow the invoking environment to pass the exact installer URL
# This is useful for pipelines where the curl process isn't visible to this shell
if [ -n "$SOURCE_URL" ] && [[ "$SOURCE_URL" == *"/raw.githubusercontent.com/"* ]]; then
	SRC_OWNER=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/\([^/]*\)/[^/]*/.*|\1|p')
	SRC_REPO=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/\([^/]*\)/.*|\1|p')
	SRC_REF=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
	if [ -n "$SRC_OWNER" ] && [ "$OWNER" = "kenricashe" ]; then
		OWNER="$SRC_OWNER"
		echo "OWNER set from SOURCE_URL: $OWNER"
	fi
	if [ -n "$SRC_REPO" ] && [ "$REPO" = "lucee-installer" ]; then
		REPO="$SRC_REPO"
		echo "REPO set from SOURCE_URL: $REPO"
	fi
	if [ -n "$SRC_REF" ] && [ -z "$REF" ]; then
		REF="$SRC_REF"
		echo "REF set from SOURCE_URL: $REF"
	fi
fi

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

	# Fallback: search across all processes (useful for curl | sudo bash pipelines)
	if [ -z "$URL_REF_AUTO" ]; then
		for PROC in /proc/[0-9]*/cmdline; do
			if [ -r "$PROC" ]; then
				CMDLINE=$(tr '\0' ' ' < "$PROC" 2>/dev/null)
				if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]] && [[ "$CMDLINE" == *"/lucee/linux/sys/upgrade-in-progress/install.sh"* ]]; then
					URL_REF_AUTO=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
					if [ -n "$URL_REF_AUTO" ]; then
						break
					fi
				fi
			fi
		done
	fi
	if [ -n "$URL_REF_AUTO" ]; then
		REF="$URL_REF_AUTO"
		echo "Auto-detected REF=$REF from installer URL"
	fi
fi
REF=${REF:-master}

# Show installer origin and headers to help detect CDN caching (when invoked via curl | bash)
INSTALLER_URL=""
for PID in "$PPID" "$$"; do
	if [ -r "/proc/$PID/cmdline" ]; then
		CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
		if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]]; then
			INSTALLER_URL=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*\(https://raw.githubusercontent.com/[^ ]*\).*|\1|p' | head -n1)
			if [ -n "$INSTALLER_URL" ]; then
				break
			fi
		fi
	fi
done

# Fallback: search across all processes (useful for curl | sudo bash pipelines)
if [ -z "$INSTALLER_URL" ]; then
	for PROC in /proc/[0-9]*/cmdline; do
		if [ -r "$PROC" ]; then
			CMDLINE=$(tr '\0' ' ' < "$PROC" 2>/dev/null)
			if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]] && [[ "$CMDLINE" == *"/lucee/linux/sys/upgrade-in-progress/install.sh"* ]]; then
				CANDIDATE_URL=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*\(https://raw.githubusercontent.com/[^ ]*\).*|\1|p' | head -n1)
				if [ -n "$CANDIDATE_URL" ]; then
					INSTALLER_URL="$CANDIDATE_URL"
					break
				fi
			fi
		fi
	done
fi

# Prefer SOURCE_URL for header diagnostics if provided
if [ -n "$SOURCE_URL" ] && [[ "$SOURCE_URL" == *"/raw.githubusercontent.com/"* ]]; then
	INSTALLER_URL="$SOURCE_URL"
fi

RAW_URL_DERIVED="https://raw.githubusercontent.com/$OWNER/$REPO/$REF/lucee/linux/sys/upgrade-in-progress/install.sh"

echo ""
if [ -n "$INSTALLER_URL" ]; then
	echo "Installer URL (detected): $INSTALLER_URL"
	HEADERS=""
	if HEADERS=$(curl -sIL "$INSTALLER_URL" 2>/dev/null); then
		:
	else
		echo "Failed to retrieve headers for $INSTALLER_URL"
	fi
	if [ -n "$HEADERS" ]; then
		LM=$(printf '%s\n' "$HEADERS" | awk -F': *' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
		ET=$(printf '%s\n' "$HEADERS" | awk -F': *' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
		if [ -n "$LM" ]; then
			echo "Installer Last-Modified: $LM"
		fi
		if [ -n "$ET" ]; then
			echo "Installer ETag: $ET"
		fi
		if [ -z "$LM" ] && [ -z "$ET" ]; then
			echo "Installer response headers:" 
			printf '%s\n' "$HEADERS"
		fi
	else
		echo "No headers received for $INSTALLER_URL"
	fi

	if [ "$INSTALLER_URL" != "$RAW_URL_DERIVED" ]; then
		echo ""
		echo "Derived URL (from OWNER/REPO/REF): $RAW_URL_DERIVED"
		HEADERS2=""
		if HEADERS2=$(curl -sIL "$RAW_URL_DERIVED" 2>/dev/null); then
			:
		else
			echo "Failed to retrieve headers for $RAW_URL_DERIVED"
		fi
		if [ -n "$HEADERS2" ]; then
			LM2=$(printf '%s\n' "$HEADERS2" | awk -F': *' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
			ET2=$(printf '%s\n' "$HEADERS2" | awk -F': *' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
			if [ -n "$LM2" ]; then
				echo "Derived Last-Modified: $LM2"
			fi
			if [ -n "$ET2" ]; then
				echo "Derived ETag: $ET2"
			fi
			if [ -z "$LM2" ] && [ -z "$ET2" ]; then
				echo "Derived response headers:" 
				printf '%s\n' "$HEADERS2"
			fi
		else
			echo "No headers received for $RAW_URL_DERIVED"
		fi
	fi
else
	echo "Installer URL not detected from process tree."
	echo "Derived URL (from OWNER/REPO/REF): $RAW_URL_DERIVED"
	HEADERS=""
	if HEADERS=$(curl -sIL "$RAW_URL_DERIVED" 2>/dev/null); then
		:
	else
		echo "Failed to retrieve headers for $RAW_URL_DERIVED"
	fi
	if [ -n "$HEADERS" ]; then
		LM=$(printf '%s\n' "$HEADERS" | awk -F': *' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
		ET=$(printf '%s\n' "$HEADERS" | awk -F': *' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
		if [ -n "$LM" ]; then
			echo "Derived Last-Modified: $LM"
		fi
		if [ -n "$ET" ]; then
			echo "Derived ETag: $ET"
		fi
		if [ -z "$LM" ] && [ -z "$ET" ]; then
			echo "Derived response headers:" 
			printf '%s\n' "$HEADERS"
		fi
	else
		echo "No headers received for $RAW_URL_DERIVED"
	fi
fi

echo ""
echo "Using: OWNER=$OWNER REPO=$REPO REF=$REF"

# Detect mismatch between REF and the branch referenced in the installer URL (if available)
SCRIPT_REF=""

# Prefer SOURCE_URL for mismatch detection if provided
if [ -n "$SOURCE_URL" ] && [[ "$SOURCE_URL" == *"/raw.githubusercontent.com/"* ]]; then
	URL_REF_FROM_SRC=$(printf '%s\n' "$SOURCE_URL" | sed -n 's|.*/raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
	if [ -n "$URL_REF_FROM_SRC" ]; then
		SCRIPT_REF="$URL_REF_FROM_SRC"
	fi
fi

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

# Fallback: search across all processes (useful for curl | sudo bash pipelines)
if [ -z "$SCRIPT_REF" ]; then
	for PROC in /proc/[0-9]*/cmdline; do
		if [ -r "$PROC" ]; then
			CMDLINE=$(tr '\0' ' ' < "$PROC" 2>/dev/null)
			if [[ "$CMDLINE" == *"/raw.githubusercontent.com/"* ]] && [[ "$CMDLINE" == *"/lucee/linux/sys/upgrade-in-progress/install.sh"* ]]; then
				SCRIPT_REF=$(printf '%s\n' "$CMDLINE" | sed -n 's|.*raw.githubusercontent.com/[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
				if [ -n "$SCRIPT_REF" ]; then
					break
				fi
			fi
		fi
	done
fi

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
