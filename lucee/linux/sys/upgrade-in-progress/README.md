# "Upgrade in Progress" for Lucee + Apache

Web-based status notifications during Lucee upgrades are a Catch-22 because Lucee itself is not running during the upgrade, which results in an ugly "503 Service Unavailable" error. `ErrorDocument 503` can be defined to make that error page more user-friendly, but that page is only displayed when Lucee is not running.

In actual practice it's safest to keep displaying the "Upgrade in Progress" notification not just until after the upgrade is complete, but more importantly until *thorough QA testing* has been completed. (For instructions see below.)

If your Lucee scripts are proxied from Apache through AJP/Tomcat (a very common configuration), this package is for you!

The bash shell scripts, Apache configuration files, and a status page template are deployed into `/opt/lucee/sys/upgrade-in-progress/` to begin and end the display of an "Upgrade in Progress" notification in response to Lucee requests for *every website on your server* that has been configured for this flip-a-switch style automation (see VirtualHost config below).

There are even optional scripts to automatically generate the editable list of sites to be configured, and to apply those configurations.

And finally, from the end user's perspective, their original requested URL does not change. That way the upgrade status can be shown without redirecting to a different page. The user will see the notice of how the page will automatically refresh when the upgrade is complete! That is implemented via JavaScript fetch with the HEAD method, which is more efficient than repeatedly refreshing the page.

## Typical upgrade command sequence:

```bash
$ sudo /opt/lucee/sys/upgrade-in-progress/begin.sh
Enabling lucee-upgrade-in-progress configuration...
Disabling lucee-ajp-and-mod_cfml configuration...
Reloading Apache...
DONE!

[... UPGRADE AND QA TEST ...]

$ sudo /opt/lucee/sys/upgrade-in-progress/end.sh
Enabling lucee-ajp-and-mod_cfml configuration...
Disabling lucee-upgrade-in-progress configuration...
Reloading Apache...
DONE!
```

## Apache Configuration

Two separate `.conf` files are used to cleanly manage normal Lucee operation vs Upgrade in Progress:

- **`lucee-ajp-and-mod_cfml.conf`**  
  Handles AJP proxying and mod_cfml. Must be disabled during upgrades because apparently mod_proxy and/or mod_cfml execute *before* mod_rewrite, which would bypass the upgrade rewrite rules.

- **`lucee-upgrade-in-progress.conf`**  
  Defines LUCEE_UPGRADE_IN_PROGRESS, enabling Apache rewrite rules (in each <VirtualHost>) to route CFML requests to a static `upgrade-in-progress.html`. Initially you will need to save it as `lucee-upgrade-in-progress.disabled`.

### Typical Apache configuration file locations:

- Debian/Ubuntu/Pop!_OS/etc: `/etc/apache2/conf-available/`
- RHEL/CentOS/AlmaLinux/etc: `/etc/httpd/conf.d/`
- cPanel: `/etc/apache2/conf.d`

If needed, consult Apache documentation for full details on how to enable the `.conf` files.

### Auto-install/ensure of global Apache configs

`configure-apache.sh` will ensure the global toggle files exist and default to a safe normal state (AJP/mod_cfml enabled; upgrade flag disabled). Per-site Includes reference `/opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf`.

- __Debian/Ubuntu__
  - If missing, installs `/opt/lucee/sys/upgrade-in-progress/lucee-upgrade-in-progress.conf` into `/etc/apache2/conf-available/`.
  - Ensures `lucee-upgrade-in-progress` is disabled by default (`a2disconf lucee-upgrade-in-progress`).
  - If `lucee-ajp-and-mod_cfml.conf` is missing in `conf-available`, auto-generates it from the template by parsing Tomcat's `server.xml` (AJP port/secret and `ModCFML_SharedKey`), then ensures it is enabled (`a2enconf`).

- __RHEL/CentOS/AlmaLinux__
  - Ensures `/etc/httpd/conf.d/lucee-upgrade-in-progress.disabled` exists (installs from `/opt/...` if needed).
  - If an active `.conf` exists, renames it to `.disabled` to enforce normal state.
  - If `lucee-ajp-and-mod_cfml.conf.disabled` exists, renames it to `.conf` to ensure normal state.
  - If neither `lucee-ajp-and-mod_cfml.conf` nor `.disabled` exists in `conf.d`, auto-generates `lucee-ajp-and-mod_cfml.conf` from the template by parsing `server.xml` (enabled for normal state).

- __cPanel__
  - Same pattern under `/etc/apache2/conf.d/`.
  - If neither `lucee-ajp-and-mod_cfml.conf` nor `.disabled` exists in `conf.d`, auto-generates `lucee-ajp-and-mod_cfml.conf` from the template by parsing `server.xml` (enabled for normal state).
  - Global changes are followed by `/scripts/rebuildhttpdconf` and a graceful restart when the script completes its site configuration phase.

## Example `lucee-ajp-and-mod_cfml.conf`:

```apache
<IfModule mod_proxy.c>
	ProxyPreserveHost On
	ProxyPassMatch ^/(.+\.cf[msc])(/.*)?$ ajp://127.0.0.1:8009/$1$2 flushpackets=on secret=REDACTED
	ProxyPassMatch ^/(.+\.cfml)(/.*)?$ ajp://127.0.0.1:8009/$1$2 flushpackets=on secret=REDACTED
	ProxyPassReverse / ajp://127.0.0.1:8009/ secret=REDACTED
	LoadModule modcfml_module modules/mod_cfml.so
</IfModule>

<IfModule mod_cfml.c>
	CFMLHandlers ".cfm .cfs .cfc .cfml"
	ModCFML_SharedKey "REDACTED"
	LogHeaders false
	LogHandlers false
	LogAliases false
	VDirHeader false
</IfModule>
```

Note: The examples herein include .cfc as that is the Lucee installer's default config, but for maximum security you may prefer to exclude .cfc in all of your Apache configs.

### AJP/mod_cfml template and auto-population

- A template file `lucee-ajp-and-mod_cfml.conf` is included in this package at:
  - `/opt/lucee/sys/upgrade-in-progress/lucee-ajp-and-mod_cfml.conf`
- `configure-apache.sh` will auto-generate the active global AJP config by reading Tomcat's `server.xml` to fill in:
  - AJP port (replacing `ajp://127.0.0.1:8009/`)
  - AJP secret (replacing `secret=REDACTED`)
  - `ModCFML_SharedKey` (replacing `REDACTED`)
- Default `server.xml` search paths:
  - `/opt/lucee/tomcat/conf/server.xml`, `/opt/lucee/tomcat*/conf/server.xml`, `/etc/tomcat*/server.xml`
- Override via environment variable before running: `export TOMCAT_SERVER_XML=/custom/path/server.xml`
- The generated active file is written into the appropriate global Apache directory alongside `lucee-upgrade-in-progress`:
  - Debian/Ubuntu: `/etc/apache2/conf-available/lucee-ajp-and-mod_cfml.conf`
  - RHEL/CentOS/AlmaLinux: `/etc/httpd/conf.d/lucee-ajp-and-mod_cfml.conf`
  - cPanel: `/etc/apache2/conf.d/lucee-ajp-and-mod_cfml.conf`

## Inline handling of ErrorDocument 404

For sites that use a local ErrorDocument 404 pointing to a CFML handler (e.g., `/404.cfm`), the script manages that directive inline within each site's VirtualHost (Debian/RHEL) or cPanel userdata include files:

- The existing `ErrorDocument 404` line targeting any `.cf*` file is wrapped in:
  - `<IfDefine !LUCEE_UPGRADE_IN_PROGRESS> ... </IfDefine>`
- If the directive is located in `.htaccess`, it is migrated into the vhost/userdata file and the original line in `.htaccess` is commented out with a note (see rationale below). Any contiguous preceding comments are preserved during migration.
- When upgrade mode is active, the wrapper prevents the local 404 from intercepting requests; Apache instead serves `upgrade-in-progress.html` via the per-site Include to `/opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf`.

Note on precedence and normalization:
- Migration/wrapping occurs only if the last effective `ErrorDocument 404` targets a CFML handler (`.cfm/.cfml/.cfc/.cfs`). If the last 404 is non‑CF, local 404 handling is left unchanged.
- When migration/wrapping occurs, all `ErrorDocument 404` directives in the same scope are commented out with an explanatory note (this includes non‑CF targets).
- If `.htaccess` has an eligible 404 (last is CF), it takes precedence: all 404s in `.htaccess` are commented, and any 404s in vhost/userdata are also commented as superseded; the inserted wrapped block becomes authoritative.

Rationale: Apache applies the last `ErrorDocument 404` directive in a scope; `.htaccess` cannot use `<IfDefine>`. To exactly mirror Apache’s behavior and to make upgrade toggling reliable, we only migrate when the last handler is CF, and we comment out all other 404 directives. This yields one authoritative handler wrapped in `<IfDefine>`.

## Example `lucee-upgrade-in-progress.conf`:

```apache
Define LUCEE_UPGRADE_IN_PROGRESS
```

Yes it is just a simple flag! It will be referenced later in each site's VirtualHost config.

## Example `lucee-detect-upgrade.conf`:

```apache
<IfDefine LUCEE_UPGRADE_IN_PROGRESS>
    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule ^.*\.(cfm|cfml|cfs|cfc)(/.*)?$ /upgrade-in-progress.html [L]
    </IfModule>
    <IfModule headers_module>
        # Signal to the status page via HEAD that upgrade mode is active
        Header set X-Lucee-Upgrade "1"
        Header set Cache-Control "no-store, no-cache, must-revalidate"
    </IfModule>
    # Friendly url routing e.g. /login => /login.cfm
    # is normally handled by 404.cfm, but when
    # Lucee is not running, this is needed:
    ErrorDocument 404 /upgrade-in-progress.html
</IfDefine>
```

Note: This relies on Apache mod_headers to set the `X-Lucee-Upgrade` header used by the status page for efficient HEAD polling.
 - Debian/Ubuntu: `a2enmod headers && systemctl reload apache2`
 - RHEL/CentOS/AlmaLinux and cPanel: `headers_module` is typically enabled by default, but may require manual enablement on some systems.

## Example VirtualHost:

```apache
<VirtualHost *:443>

	ServerName example.com
	[other config here ...]

    # inserted by configure-apache.sh (same path for all environments)
    Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf
	
</VirtualHost>
```

## Example `/upgrade-in-progress.html`:

This template does the job for any site, or you can customize the branding, etc, specific to each site. Deploy as you see fit.

When QA testing you can change to: `const numInterval = 1000;`

Note: The shipped template auto-detects development hostnames (containing `dev.`) and uses a shorter 2-second polling interval; otherwise it polls every 60 seconds. You can customize this behavior in `/opt/lucee/sys/upgrade-in-progress/upgrade-in-progress.html`.

```html
<!DOCTYPE html>
<html>
<head>
<title>Upgrade In Progress</title>
<script>
window.addEventListener('DOMContentLoaded', function() {
	const numInterval = 60000;
	function checkUpgradeStatus() {
		fetch(window.location.href, { method: 'HEAD', cache: 'no-cache' })
		.then(response => {
			const isUpgrade = response.headers.get('X-Lucee-Upgrade') === '1';
			if (!isUpgrade) window.location.reload();
		})
		.catch(error => {
			console.log('Error checking upgrade status:', error);
		});
	}
	checkUpgradeStatus();
	setInterval(checkUpgradeStatus, numInterval);
});
</script>
</head>
<body>
<h1>Upgrade In Progress</h1>
<p>We are currently upgrading our website.</p>
<p>This page will automatically refresh when the upgrade is complete!</p>
</body>
</html>
```

## Post-Upgrade Testing

For QA testing after the upgrade, you can exclude one of your sites from the list of sites that will be disabled, simply by editing the `/opt/lucee/sys/upgrade-in-progress/sites-configured.txt` file. Be sure to not provide any public links to that QA site. You may also want to disable it when you are done QA testing.

## Automation Notes

- Files deploy to `/opt/lucee/sys/upgrade-in-progress/` via `deploy-to-opt-lucee-sys.sh`.
- `configure-apache.sh` auto-installs/ensures global Apache configs to safe defaults:
  - Debian/Ubuntu: installs to `conf-available` if missing, leaves upgrade flag disabled, ensures AJP/mod_cfml enabled if present.
  - RHEL/CentOS/AlmaLinux and cPanel: ensures `.disabled` exists in `conf.d`, disables active upgrade flag if present, ensures AJP/mod_cfml enabled.
- `configure-apache.sh` warns if AJP proxying is not detected in the global Apache configuration.
- `configure-apache.sh` also scans global Apache config for existing AJP/mod_cfml directives (ProxyPass/Match/Reverse ajp://, LoadModule mod_cfml, ModCFML_SharedKey) and warns if duplicates are found outside the managed `lucee-ajp-and-mod_cfml.conf`. Remove any duplicates to avoid conflicts. Commented lines are ignored.
- `configure-apache.sh` auto-generates `lucee-ajp-and-mod_cfml.conf` in the global Apache directory from the template in `/opt/lucee/sys/upgrade-in-progress/` by parsing Tomcat's `server.xml`. Override with `TOMCAT_SERVER_XML` env var if needed.
- `configure-apache.sh` injects per-VirtualHost (or cPanel userdata) Includes pointing to:
  - All environments: `/opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf`
  
  Additional per-site handling:
  - For sites WITH a local `ErrorDocument 404` pointing to a `.cf*` target (with404): the directive is wrapped inline within the vhost/userdata under `<IfDefine !LUCEE_UPGRADE_IN_PROGRESS>`.
  - For sites where the directive exists in `.htaccess`: it is migrated to the vhost/userdata (contiguous preceding comments preserved) and the original line in `.htaccess` is commented out with a note explaining the migration.
  - For sites WITHOUT such a directive (no404): only the per-site Include to `/opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf` is added; no local 404 is injected.
- Debian/Ubuntu: updates both HTTPS vhosts (e.g., `domain-ssl.conf`) and HTTP vhosts (`domain.conf`) where present.
- cPanel: writes userdata to BOTH trees, then rebuilds httpd config and gracefully restarts:
  - SSL: `/etc/apache2/conf.d/userdata/ssl/2_4/<user>/<domain>/lucee.conf`
  - STD: `/etc/apache2/conf.d/userdata/std/2_4/<user>/<domain>/lucee.conf`
  - Commands: `/scripts/rebuildhttpdconf` and `/scripts/restartsrv_httpd --graceful`
- RHEL/CentOS/AlmaLinux: updates HTTPS and HTTP VirtualHosts under `/etc/httpd/conf.d/*.conf` and `/etc/httpd/conf/httpd.conf`, inserting per-site Include and migrating/wrapping local 404s where applicable.

- `configure-apache.sh` will warn if Apache `mod_headers` is not enabled, since the status page relies on the `X-Lucee-Upgrade` response header for HEAD polling.

### Sites file format (`sites-configured.txt`)

- Generated by `get-lucee-sites.sh` and consumed by `configure-apache.sh`.
- Format: two required columns per line: `domain docroot`
  - Optional third column `site_type` is supported and currently used for logging/labeling only (e.g., `primary`, `staging`, `dev`).
  - Full format: `domain docroot [site_type]`
  - Example:
    - `example.com /var/www/example.com/public_html`
    - `sub.example.com /home/user/public_html/sub`
    - `example.org /srv/web/example.org/public primary`

### Centralized backups

`configure-apache.sh` saves backups under a centralized root, mirroring the original file paths:

- Root: `/opt/lucee/sys/upgrade-in-progress/backups/`
- Layout: `<BACKUP_ROOT>/<YYYY-mm-dd-HHMMSS><original_path>` (original_path starts with `/` so each backup set is in its own timestamped folder)
- All backups from a single run share the same `<YYYY-mm-dd-HHMMSS>` folder for easier rollback.

Examples:

- Debian vhost edit: `/etc/apache2/sites-available/example-ssl.conf` → `/opt/lucee/sys/upgrade-in-progress/backups/2025-01-01-123045/etc/apache2/sites-available/example-ssl.conf`
- Debian sites-enabled repair: `/etc/apache2/sites-enabled/example-ssl.conf` (unexpected file) → `/opt/lucee/sys/upgrade-in-progress/backups/2025-01-01-123045/etc/apache2/sites-enabled/example-ssl.conf`
- cPanel userdata: `/etc/apache2/conf.d/userdata/ssl/2_4/user/example.com/lucee.conf` → `/opt/lucee/sys/upgrade-in-progress/backups/2025-01-01-123045/etc/apache2/conf.d/userdata/ssl/2_4/user/example.com/lucee.conf`
- Docroot asset: `/var/www/example.com/public_html/upgrade-in-progress.html` → `/opt/lucee/sys/upgrade-in-progress/backups/2025-01-01-123045/var/www/example.com/public_html/upgrade-in-progress.html`
- RHEL/cPanel global: `/etc/httpd/conf.d/lucee-upgrade-in-progress.disabled` (pre-existing) → `/opt/lucee/sys/upgrade-in-progress/backups/2025-01-01-123045/etc/httpd/conf.d/lucee-upgrade-in-progress.disabled`

Backups are created only when a file already exists and is about to be modified or replaced.

Important: Even with HTTP vhosts configured for upgrade mode, you should maintain a proper 80→443 redirect in normal operation to avoid exposure over HTTP.