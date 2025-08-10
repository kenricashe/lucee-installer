#!/bin/bash

# Deploy:
# cd /path/to/this/script
# cp ./configure-sites.sh /opt/lucee/sys/upgrade-in-progress/configure-sites.sh
# chmod +x /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# Update:
# cat ./configure-sites.sh | sudo tee /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# Execute:
# sudo /opt/lucee/sys/upgrade-in-progress/configure-sites.sh

# require root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root or with sudo."
	exit 1
fi

# Resolve this script directory and compute LUCEE_ROOT and UPG_DIR
SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SOURCE" ]; do
	DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
	LINK="$(readlink "$SOURCE")"
	if [[ "$LINK" != /* ]]; then
		SOURCE="$DIR/$LINK"
	else
		SOURCE="$LINK"
	fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
LUCEE_ROOT="$("$SCRIPT_DIR/get-lucee-root.sh")"
UPG_DIR="${LUCEE_ROOT}/sys/upgrade-in-progress"

	# preflight: required files must exist at /opt path used by per-site Includes and docroot copy
	DETECT_CONF="${UPG_DIR}/lucee-detect-upgrade.conf"
	UPG_HTML="${UPG_DIR}/upgrade-in-progress.html"
	if [ ! -f "$DETECT_CONF" ]; then
		echo "Error: Required include not found: $DETECT_CONF"
		echo "Run deploy-to-opt-lucee-sys.sh to deploy the package, then retry."
		exit 1
	fi
	if [ ! -f "$UPG_HTML" ]; then
		echo "Error: Required HTML not found: $UPG_HTML"
		echo "Run deploy-to-opt-lucee-sys.sh to deploy the package, then retry."
		exit 1
	fi

ERROR404_LINE='ErrorDocument 404 /404.cfm?%{REQUEST_URI}&%{QUERY_STRING}'
ERROR404_REGEX='^[[:space:]]*ErrorDocument[[:space:]]+404[[:space:]]+/[^[:space:]]*\.(cfm|cfml|cfc|cfs)([^[:alnum:]_]|$)'

SITES_FILE="${UPG_DIR}/sites-configured.txt"
if [ ! -f "$SITES_FILE" ]; then
	echo "Lucee sites data file not found. You first need to run:"
	echo "sudo ${UPG_DIR}/get-lucee-sites.sh"
	echo "Then review and if necessary edit the .txt file"
	echo "from that before returning to this script."
	exit 1
fi

# prep cPanel flag
if [ -f "/usr/local/cpanel/cpanel" ]; then
	IS_CPANEL=true
	CPANEL_USERDATA_SSL_PATH="/etc/apache2/conf.d/userdata/ssl/2_4"
	CPANEL_USERDATA_STD_PATH="/etc/apache2/conf.d/userdata/std/2_4"
else
	IS_CPANEL=false
fi

# Centralized backup root; backs up mirror paths beneath this directory
BACKUP_ROOT="${UPG_DIR}/backups"
# Single timestamp for this run; all backups go under this subfolder for easy restore
BACKUP_TS="$(date +%Y-%m-%d-%H%M%S)"

# LUCEE_ROOT is available via helper; UPG_DIR already computed above

# Apache config test helper: prefer apache2ctl, then apachectl, then httpd
apache_config_test() {
	if command -v apache2ctl >/dev/null 2>&1; then
		apache2ctl -t
	elif command -v apachectl >/dev/null 2>&1; then
		apachectl -t
	elif command -v httpd >/dev/null 2>&1; then
		httpd -t
	else
		echo "Warning: No apache control binary found for config test; skipping syntax check."
		return 0
	fi
}

# Backup helper: mirror source path under ${BACKUP_ROOT}/${BACKUP_TS}
backup_file() {
	local src="$1"
	[ -f "$src" ] || return 0
	local dest="${BACKUP_ROOT}/${BACKUP_TS}${src}"
	local dest_dir
	dest_dir=$(dirname "$dest")
	mkdir -p "$dest_dir"
	cp -f "$src" "$dest"
}

# Extract the first matching ErrorDocument 404 *.cf* line and its contiguous preceding comments
# Prints the block to stdout; returns non-zero if not found
extract_404_block() {
	local file="$1"
	[ -f "$file" ] || return 1
	awk -v IGNORECASE=1 -v pat="$ERROR404_REGEX" '
		{ lines[++n]=$0 }
		$0 ~ pat && ln==0 { ln=n }
		END {
			if (!ln) exit 1
			start=ln-1
			while (start>=1 && (lines[start] ~ /^[\t ]*#/ || lines[start] ~ /^[\t ]*$/)) start--
			for (i=start+1; i<ln; i++) print lines[i]
			print lines[ln]
		}
	' "$file"
}

# Remove the first matching ErrorDocument 404 *.cf* line and its contiguous preceding comments from file (in-place)
remove_404_block() {
	local file="$1"
	[ -f "$file" ] || return 0
	local tmp
	tmp=$(mktemp)
	awk -v IGNORECASE=1 -v pat="$ERROR404_REGEX" '
		{ lines[++n]=$0 }
		$0 ~ pat && ln==0 { ln=n }
		END {
			if (!ln) {
				for (i=1;i<=n;i++) print lines[i]
				exit 0
			}
			start=ln-1
			while (start>=1 && (lines[start] ~ /^[\t ]*#/ || lines[start] ~ /^[\t ]*$/)) start--
			for (i=1;i<=n;i++) if (i<start+1 || i>ln) print lines[i]
		}
	' "$file" > "$tmp"
	if [ $? -eq 0 ]; then
		mv -f "$tmp" "$file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Insert a wrapped block before </VirtualHost> in the given vhost file
insert_wrapped_block_before_vhost_close() {
	local vhost_file="$1"
	local block_text="$2"
	[ -f "$vhost_file" ] || return 1
	local tmp
	tmp=$(mktemp)
	awk -v blk="$block_text" '
		BEGIN{ done=0 }
		/<\/VirtualHost>/ && !done {
			print "\t<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>"
			print blk
			print "\t</IfDefine>"
			done=1
		}
		{ print }
	' "$vhost_file" > "$tmp"
	if [ $? -eq 0 ]; then
		mv -f "$tmp" "$vhost_file"
	else
		rm -f "$tmp"
		return 1
	fi
}

# Check if mod_headers is enabled (needed for X-Lucee-Upgrade header polling)
headers_module_enabled() {
	if command -v apache2ctl >/dev/null 2>&1; then
		apache2ctl -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	elif command -v apachectl >/dev/null 2>&1; then
		apachectl -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	elif command -v httpd >/dev/null 2>&1; then
		httpd -M 2>/dev/null | grep -qiE '(^|[^[:alnum:]_])headers_module([^[:alnum:]_]|$)'
		return $?
	fi
	# If we can't detect, do not block; treat as enabled to avoid false alarms
	return 0
}

# Warn if conflicting AJP/mod_cfml directives already exist in global config
warn_existing_ajp_modcfml() {
	# Args: list of directories to scan
	local found=""
	local dir
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		local hits
		# Only match active (non-commented) lines with AJP/mod_cfml directives, excluding our managed file
		hits=$(grep -RniE '^[[:space:]]*[^#].*(ProxyPass(Match|Reverse).*ajp://|ModCFML_SharedKey|LoadModule[[:space:]]+modcfml_module)' "$dir" 2>/dev/null | grep -v 'lucee-ajp-and-mod_cfml.conf' || true)
		if [ -n "$hits" ]; then
			found+="\n${hits}"
		fi
	done
	if [ -n "$found" ]; then
		echo "Warning: Existing AJP/mod_cfml directives detected in global Apache config."
		echo "They may conflict with the generated lucee-ajp-and-mod_cfml.conf. Please remove duplicates:"
		echo "$found"
	fi
}

# Resolve Tomcat server.xml path
resolve_server_xml() {
	if [ -n "$TOMCAT_SERVER_XML" ] && [ -f "$TOMCAT_SERVER_XML" ]; then
		echo "$TOMCAT_SERVER_XML"
		return 0
	fi

	for candidate in \
		"${LUCEE_ROOT}/tomcat/conf/server.xml" \
		"${LUCEE_ROOT}/tomcat*/conf/server.xml" \
		"/etc/tomcat*/server.xml"; do
		if ls $candidate >/dev/null 2>&1; then
			# Return the first match from glob expansion
			for f in $candidate; do
				[ -f "$f" ] && { echo "$f"; return 0; }
			done
		fi
	done
	echo "" # not found
}

# Parse AJP port/secret and mod_cfml shared key from server.xml
parse_server_xml() {
	local sx="$1"
	AJP_PORT="8009" # default fallback
	AJP_SECRET=""
	MODCFML_SHARED_KEY=""
	if [ -f "$sx" ]; then
		# AJP Connector line
		local ajp_line
		ajp_line=$(grep -i "<Connector" "$sx" | grep -i "ajp" | head -n1 || true)
		if [ -n "$ajp_line" ]; then
			AJP_PORT=$(echo "$ajp_line" | sed -n 's/.*port="\([0-9]\{2,5\}\)".*/\1/p')
			AJP_SECRET=$(echo "$ajp_line" | sed -n 's/.*secret="\([^"]\+\)".*/\1/p')
		fi
		# mod_cfml Valve line
		local vline
		vline=$(grep -i "<Valve" "$sx" | grep -i "mod_cfml" | head -n1 || true)
		if [ -n "$vline" ]; then
			MODCFML_SHARED_KEY=$(echo "$vline" | sed -n 's/.*sharedKey="\([^"]\+\)".*/\1/p')
			if [ -z "$MODCFML_SHARED_KEY" ]; then
				MODCFML_SHARED_KEY=$(echo "$vline" | sed -n 's/.*secret="\([^"]\+\)".*/\1/p')
			fi
		fi
	fi
}

# Render the AJP+mod_cfml template into a destination file
render_ajp_template() {
	local dest="$1"
	local tmpl="${UPG_DIR}/lucee-ajp-and-mod_cfml.conf"
	if [ ! -f "$tmpl" ]; then
		echo "Warning: Template not found: $tmpl"
		return 1
	fi
	local sx
	sx=$(resolve_server_xml)
	parse_server_xml "$sx"
	# build replacement values
	local port="$AJP_PORT"
	local ajpsec="$AJP_SECRET"
	local shared="$MODCFML_SHARED_KEY"
	# escape for sed
	local esc_ajpsec esc_shared
	esc_ajpsec=$(printf '%s' "$ajpsec" | sed -e 's/[\&/]/\\&/g')
	esc_shared=$(printf '%s' "$shared" | sed -e 's/[\&/]/\\&/g')
	# substitute: port 8009 -> actual port; secrets replace REDACTED
	sed \
		-e "s#ajp://127.0.0.1:8009/#ajp://127.0.0.1:${port}/#g" \
		-e "s#secret=REDACTED#secret=${esc_ajpsec}#g" \
		-e "s#ModCFML_SharedKey \"REDACTED\"#ModCFML_SharedKey \"${esc_shared}\"#g" \
		"$tmpl" > "$dest"
	chmod 644 "$dest"
	# Post-render warnings
	if [ -z "$ajpsec" ]; then
		echo "Warning: AJP secret not found in server.xml (${sx:-unknown}). You should set an AJP secret and update Apache accordingly."
	fi
	if [ -z "$shared" ]; then
		echo "Warning: mod_cfml shared key not found in server.xml (${sx:-unknown}). You should set ModCFML_SharedKey consistently."
	fi
}

# Ensure global Apache confs exist and are set to normal-state defaults
# Normal state: AJP/mod_cfml enabled; upgrade flag disabled
ensure_global_confs() {
	# Debian/Ubuntu
	if command -v a2enconf >/dev/null 2>&1; then
		conf_avail="/etc/apache2/conf-available"
		opt_file="${UPG_DIR}/lucee-upgrade-in-progress.conf"
		if [ -f "$opt_file" ] && [ ! -f "${conf_avail}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.conf into ${conf_avail}/"
			cp -f "$opt_file" "${conf_avail}/lucee-upgrade-in-progress.conf"
		fi
		# Warn if conflicting AJP/mod_cfml config is present elsewhere in global dirs
		warn_existing_ajp_modcfml \
			"/etc/apache2/conf-available" \
			"/etc/apache2/conf-enabled"
		# Ensure AJP+mod_cfml global conf exists (generate from template if missing)
		if [ ! -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ]; then
			echo "Generating global lucee-ajp-and-mod_cfml.conf in ${conf_avail}/ from template via server.xml"
			render_ajp_template "${conf_avail}/lucee-ajp-and-mod_cfml.conf" || true
		fi
		# Ensure upgrade flag is disabled by default
		a2disconf lucee-upgrade-in-progress >/dev/null 2>&1 || true
		# Ensure AJP+mod_cfml is enabled if present in conf-available
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ]; then
			a2enconf lucee-ajp-and-mod_cfml >/dev/null 2>&1 || true
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${conf_avail}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "/etc/apache2/conf-enabled/lucee-ajp-and-mod_cfml.conf" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' /etc/apache2/ 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (Debian/Ubuntu). Normal operation expects AJP/mod_cfml enabled."
		fi
		# Warn if mod_headers isn't enabled (needed for HEAD-based polling via X-Lucee-Upgrade)
		if ! headers_module_enabled; then
			echo "Warning: Apache mod_headers does not appear to be enabled."
			echo "The upgrade status page relies on X-Lucee-Upgrade header for HEAD polling."
			echo "Enable with: a2enmod headers && systemctl reload apache2"
		fi
		return
	fi

	# RHEL family and cPanel
	if [ -d /etc/httpd/conf.d ] || [ -d /etc/apache2/conf.d ]; then
		if [ "$IS_CPANEL" = true ]; then
			confd="/etc/apache2/conf.d"
		else
			confd="/etc/httpd/conf.d"
		fi
		opt_file="${UPG_DIR}/lucee-upgrade-in-progress.conf"
		# Ensure a disabled copy exists if neither form exists
		if [ -f "$opt_file" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.disabled" ] && [ ! -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			echo "Installing global lucee-upgrade-in-progress.disabled into ${confd}/"
			cp -f "$opt_file" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Warn if conflicting AJP/mod_cfml config is present elsewhere in global dir
		warn_existing_ajp_modcfml "$confd"
		# Ensure AJP+mod_cfml global conf exists (generate from template if missing)
		if [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf" ] && [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ]; then
			echo "Generating global ${confd}/lucee-ajp-and-mod_cfml.conf from template via server.xml (enabled in normal state)"
			render_ajp_template "${confd}/lucee-ajp-and-mod_cfml.conf" || true
		fi
		# Ensure normal state: upgrade flag disabled
		if [ -f "${confd}/lucee-upgrade-in-progress.conf" ]; then
			# Backup existing .disabled if present to avoid clobbering (mirrored under BACKUP_ROOT)
			if [ -f "${confd}/lucee-upgrade-in-progress.disabled" ]; then
				echo "Backing up existing ${confd}/lucee-upgrade-in-progress.disabled"
				backup_file "${confd}/lucee-upgrade-in-progress.disabled"
			fi
			echo "Disabling lucee-upgrade-in-progress.conf (normal state)"
			mv -f "${confd}/lucee-upgrade-in-progress.conf" "${confd}/lucee-upgrade-in-progress.disabled"
		fi
		# Ensure AJP+mod_cfml is enabled (rename from .disabled if needed)
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ] && [ ! -f "${confd}/lucee-ajp-and-mod_cfml.conf" ]; then
			echo "Enabling lucee-ajp-and-mod_cfml.conf (normal state)"
			mv -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" "${confd}/lucee-ajp-and-mod_cfml.conf"
		fi
		# Warn if no AJP proxying detected in global config
		ajp_detected=false
		if [ -f "${confd}/lucee-ajp-and-mod_cfml.conf" ] || [ -f "${confd}/lucee-ajp-and-mod_cfml.conf.disabled" ]; then
			ajp_detected=true
		elif grep -Rqi 'ajp://' "$confd" 2>/dev/null; then
			ajp_detected=true
		fi
		if [ "$ajp_detected" != true ]; then
			echo "Warning: AJP proxying not detected in global Apache config (${confd}). Normal operation expects AJP/mod_cfml enabled."
		fi
		# Warn if mod_headers isn't enabled (needed for HEAD-based polling via X-Lucee-Upgrade)
		if ! headers_module_enabled; then
			echo "Warning: Apache mod_headers does not appear to be enabled."
			echo "The upgrade status page relies on X-Lucee-Upgrade header for HEAD polling."
			echo "Ensure headers_module is loaded (usually enabled by default on RHEL/cPanel)."
		fi
		return
	fi
}

# Function to copy upgrade-in-progress.html to DocumentRoot
copy_upgrade_html() {
	local docroot=$1
	# Backup existing docroot file (mirrored under BACKUP_ROOT)
	backup_file ${docroot}/upgrade-in-progress.html
	cp -f "${UPG_DIR}/upgrade-in-progress.html" ${docroot}/upgrade-in-progress.html
	chown --reference=${docroot} ${docroot}/upgrade-in-progress.html 2>/dev/null || true
}

# Function to configure Debian sites
configure_site_debian() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Processing $domain ($site_type site) with DocumentRoot: $docroot"
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Check if the SSL site in sites-enabled is a regular file (not a symlink)
	# This would happen if a previous buggy version of the script replaced the symlink
	enabled_ssl_conf="/etc/apache2/sites-enabled/${domain}-ssl.conf"
	if [ -f "$enabled_ssl_conf" ] && [ ! -L "$enabled_ssl_conf" ]; then
		echo "  Found regular file instead of symlink at $enabled_ssl_conf"
		echo "  Restoring symlink structure..."
		# Backup the unexpected regular file before removal (mirrored under BACKUP_ROOT)
		echo "  Backing up $enabled_ssl_conf"
		backup_file "$enabled_ssl_conf"
		# Get the site name without extension and remove the stray file
		site_name="${domain}-ssl"
		rm -f "$enabled_ssl_conf"
		
		# Enable the site (creates a proper symlink)
		a2ensite "$site_name" > /dev/null 2>&1
		
		echo "  Symlink restored for $site_name"
	fi
	
	# Find the SSL site configuration file in sites-available directly
	ssl_conf_file="/etc/apache2/sites-available/${domain}-ssl.conf"
	if [ ! -f "$ssl_conf_file" ]; then
		# Try to find by ServerName
		ssl_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*-ssl.conf 2>/dev/null | head -1)
	fi
	
	if [ -f "$ssl_conf_file" ]; then
		echo "  Updating $ssl_conf_file"
		# Backup before editing (mirrored under BACKUP_ROOT)
		backup_file "$ssl_conf_file"
		
		# Remove any existing Lucee upgrade includes and legacy 404 include
		sed -i '/Include.*lucee-detect-upgrade.conf/d' "$ssl_conf_file"
		sed -i '/Include.*lucee-404-routing.conf/d' "$ssl_conf_file"
		# If site has a local 404 in this vhost, capture then remove it
		local ssl_404_block=""
		if echo "" | grep -q ""; then :; fi # keep shellcheck quiet about local before use
		ssl_404_block=$(extract_404_block "$ssl_conf_file" || true)
		if [ -n "$ssl_404_block" ]; then
			echo "  Found local 404 in SSL vhost; wrapping inline"
			backup_file "$ssl_conf_file"
			remove_404_block "$ssl_conf_file"
		fi
		
		# Replace all whitespace just before closing </VirtualHost> with '\n\n'
		sed -i ':a;N;$!ba;s/\n[[:space:]]*\n*[[:space:]]*<\/VirtualHost>/\n\n<\/VirtualHost>/' "$ssl_conf_file"

		# Always include global detect config
		sed -i "s|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\\n\\n</VirtualHost>|" "$ssl_conf_file"
		# If we have a 404 block from this vhost or from .htaccess (handled below), insert it wrapped
		if [ -z "$ssl_404_block" ] && [ "$site_type" = "with404" ] && [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
			ssl_404_block=$(extract_404_block "$docroot/.htaccess" || true)
			if [ -n "$ssl_404_block" ]; then
				echo "  Migrating 404 from .htaccess into SSL vhost"
				backup_file "$docroot/.htaccess"
				remove_404_block "$docroot/.htaccess"
			fi
		fi
		if [ -n "$ssl_404_block" ]; then
			insert_wrapped_block_before_vhost_close "$ssl_conf_file" "$ssl_404_block"
		fi
	else
		echo "  Warning: Could not find SSL configuration file for $domain"
	fi

	# Also update the HTTP (port 80) VirtualHost if present
	# Find the HTTP site configuration file in sites-available
	http_conf_file="/etc/apache2/sites-available/${domain}.conf"
	if [ ! -f "$http_conf_file" ]; then
		# Try to find by ServerName, excluding -ssl.conf
		http_conf_file=$(grep -l "ServerName $domain" /etc/apache2/sites-available/*.conf 2>/dev/null | grep -v -- '-ssl\.conf' | head -1)
	fi

	if [ -f "$http_conf_file" ]; then
		echo "  Updating $http_conf_file"
		# Backup before editing (mirrored under BACKUP_ROOT)
		backup_file "$http_conf_file"
		# Remove any existing Lucee upgrade includes and legacy 404 include
		sed -i '/Include.*lucee-detect-upgrade.conf/d' "$http_conf_file"
		sed -i '/Include.*lucee-404-routing.conf/d' "$http_conf_file"
		# Capture then remove local 404 in this vhost, if any
		local http_404_block=""
		http_404_block=$(extract_404_block "$http_conf_file" || true)
		if [ -n "$http_404_block" ]; then
			echo "  Found local 404 in HTTP vhost; wrapping inline"
			backup_file "$http_conf_file"
			remove_404_block "$http_conf_file"
		fi
		# Normalize whitespace before </VirtualHost>
		sed -i ':a;N;$!ba;s/\n[[:space:]]*\n*[[:space:]]*<\/VirtualHost>/\n\n<\/VirtualHost>/' "$http_conf_file"
		# Always include global detect config
		sed -i "s|</VirtualHost>|\tInclude /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf\\n\\n</VirtualHost>|" "$http_conf_file"
		# If no 404 came from HTTP vhost, and site_type says with404, try to reuse from SSL or pull from .htaccess
		if [ -z "$http_404_block" ] && [ "$site_type" = "with404" ]; then
			if [ -n "$ssl_404_block" ]; then
				http_404_block="$ssl_404_block"
			elif [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
				http_404_block=$(extract_404_block "$docroot/.htaccess" || true)
				if [ -n "$http_404_block" ]; then
					echo "  Migrating 404 from .htaccess into HTTP vhost"
					backup_file "$docroot/.htaccess"
					remove_404_block "$docroot/.htaccess"
				fi
			fi
		fi
		if [ -n "$http_404_block" ]; then
			insert_wrapped_block_before_vhost_close "$http_conf_file" "$http_404_block"
		fi
		# Best-effort warning if HTTP VirtualHost may not redirect to HTTPS
		if ! grep -Eiq '(Redirect(\s+(permanent|temp|301|302))?\s+/?\s+https?://|RewriteRule\s+.*https://)' "$http_conf_file"; then
			echo "  Warning: HTTP vhost for $domain may not redirect to HTTPS. Ensure a proper 80->443 redirect is configured to avoid exposure over HTTP."
		fi
	else
		echo "  Info: No HTTP configuration file found for $domain"
	fi

	# If anything remains in .htaccess matching the pattern, remove it (already migrated above if with404)
	if [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
		echo "  Cleaning up 404 ErrorDocument from $docroot/.htaccess"
		backup_file "$docroot/.htaccess"
		remove_404_block "$docroot/.htaccess"
	fi
}

# Function to configure cPanel sites
configure_site_cpanel() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Processing cPanel site: $domain ($site_type site) with DocumentRoot: $docroot"
	
	# expected cPanel docroot: /home/user/public_html
	user=$(echo "$docroot" | awk -F '/' '{print $3}')
	
	# Copy upgrade-in-progress.html to DocumentRoot
	copy_upgrade_html "$docroot"
	
	# Create userdata directory
	mkdir -p ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}
	mkdir -p ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}
	
	# Prepare a 404 block from existing userdata or .htaccess if site had one previously
	local cp_404_block=""
	if [ "$site_type" = "with404" ]; then
		# Prefer .htaccess for comment preservation
		if [ -f "$docroot/.htaccess" ] && grep -qiE "$ERROR404_REGEX" "$docroot/.htaccess"; then
			cp_404_block=$(extract_404_block "$docroot/.htaccess" || true)
			if [ -n "$cp_404_block" ]; then
				echo "  Migrating 404 from .htaccess into userdata"
				backup_file "$docroot/.htaccess"
				remove_404_block "$docroot/.htaccess"
			fi
		fi
		# If still empty, try to find in existing userdata files
		if [ -z "$cp_404_block" ]; then
			for d in "${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}" "${CPANEL_USERDATA_STD_PATH}/${user}/${domain}"; do
				[ -d "$d" ] || continue
				while IFS= read -r f; do
					[ -f "$f" ] || continue
					if grep -qiE "$ERROR404_REGEX" "$f"; then
						cp_404_block=$(extract_404_block "$f" || true)
						backup_file "$f"
						remove_404_block "$f"
						break
					fi
				done < <(find "$d" -type f -maxdepth 1 2>/dev/null)
				if [ -n "$cp_404_block" ]; then
					break
				fi
			done
		fi
	fi
	# Create lucee.conf with appropriate includes
	if [ "$site_type" = "with404" ]; then
		# Root sites get both upgrade detection and 404 routing
		# Backup existing userdata files before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>
${cp_404_block}
</IfDefine>
EOF
		# Also create non-SSL userdata include
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>
${cp_404_block}
</IfDefine>
EOF
	else
		# Non-root sites get only upgrade detection
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
		# Also create non-SSL userdata include
		# Backup existing userdata file before overwriting (mirrored under BACKUP_ROOT)
		backup_file ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf
		cat > ${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf << EOF
# This file is automatically generated and managed by
# ${UPG_DIR}/configure-sites.sh
# Any manual changes will be overwritten when the script runs
Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
EOF
	fi
}

# Function to configure non-cPanel RedHat sites (placeholder)
configure_site_redhat() {
	local domain=$1
	local docroot=$2
	local site_type=$3
	
	echo "Non-cPanel RedHat configuration not implemented yet for $domain"
	echo "Pull requests are welcome!"
}

# Function to process all sites from the configuration file
process_sites() {
	local configure_func=$1
	
	# Get data from txt file
	while IFS= read -r line; do
		domain=$(echo "$line" | awk '{print $1}')
		docroot=$(echo "$line" | awk '{print $2}')
		site_type=$(echo "$line" | awk '{print $3}')
		
		$configure_func "$domain" "$docroot" "$site_type"
		
	done < $SITES_FILE
}

# Function to reload Apache
reload_apache() {
	local apache_service=$1
	echo "Reloading Apache..."
	systemctl reload $apache_service
}

# Main script execution
echo "Configuring Lucee sites for scripted 'Upgrade in Progress' notifications ..."

# Detect distribution and run appropriate code path
if command -v a2enconf >/dev/null 2>&1; then
	# Debian/Ubuntu path
	ensure_global_confs
	process_sites configure_site_debian
	# Validate Apache configuration before reload
	if ! apache_config_test; then
		echo "Apache configuration test FAILED. Aborting reload."
		exit 1
	fi
	reload_apache apache2
	
# Redhat/CentOS/AlmaLinux/etc
elif [ -d /etc/httpd/conf.d ]; then
	if [ "$IS_CPANEL" = true ]; then
		# cPanel path
		ensure_global_confs
		process_sites configure_site_cpanel
		
		# Rebuild Apache configuration and validate
		echo "Rebuilding Apache configuration..."
		/scripts/rebuildhttpdconf
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting restart."
			exit 1
		fi
		echo "Gracefully restarting httpd..."
		/scripts/restartsrv_httpd --graceful
	else
		# Non-cPanel RedHat path
		ensure_global_confs
		process_sites configure_site_redhat
		# Validate Apache configuration before reload
		if ! apache_config_test; then
			echo "Apache configuration test FAILED. Aborting reload."
			exit 1
		fi
		reload_apache httpd
	fi
else
	echo "Unsupported environment (neither a2enconf nor /etc/httpd/conf.d detected)"
	exit 1
fi			
	
# /etc/apache2/conf.d/userdata/std/2_4/${user}/${domain}/upgrade-in-progress.conf

echo "DONE!"
