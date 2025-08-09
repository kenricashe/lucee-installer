# "Upgrade in Progress" for Lucee + Apache

Web-based status notifications during Lucee upgrades are a Catch-22 because Lucee itself is not running during the upgrade, which results in an ugly "503 Service Unavailable" error. `ErrorDocument 503` can be defined to make that error page more user-friendly, but that page is only displayed when Lucee is not running.

In actual practice it's safest to keep displaying the "Upgrade in Progress" notification not just until after the upgrade is complete, but more importantly until *thorough QA testing* has been completed. (For instructions see below.)

If your Lucee scripts are proxied from Apache through AJP/Tomcat (a very common configuration), this package is for you!

The bash shell scripts, Apache configuration files, and a status page template are deployed into `/opt/lucee/sys/upgrade-in-progress/` to begin and end the display of an "Upgrade in Progress" notification in response to Lucee requests for *every website on your server* that has been configured for this flip-a-switch style automation (see VirtualHost config below).

There are even optional scripts to automatically generate the editable list of sites to be configured, and to apply those configurations.

And finally, from the end user's perspective, their original requested URL does not change. That way the upgrade status can be shown without redirecting to a different page. The user will see the notice of how the page will automatically refresh when the upgrade is complete! (That is implemented via JavaScript fetch.)

## Typical upgrade command sequence:

```bash
$ sudo /opt/lucee/sys/upgrade-in-progress/begin.sh
Enabling lucee-upgrade-in-progress configuration...
Disabling lucee-ajp-and-mod_cfml configuration...
Reloading Apache...
DONE!

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
- Redhat/CentOS/AlmaLinux/etc: `/etc/httpd/conf.d/`
- cPanel: `/etc/apache2/conf.d`

If needed, consult Apache documentation for full details on how to enable the `.conf` files.

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

## Example `lucee-upgrade-in-progress.conf`:

```apache
Define LUCEE_UPGRADE_IN_PROGRESS
```

Yes it is just a simple flag! It will be referenced later in each site's VirtualHost config.

## Example VirtualHost:

```apache
<VirtualHost *:443>

	ServerName example.com
	[other config here ...]

	<IfModule mod_rewrite.c>
		RewriteEngine On
		<IfDefine LUCEE_UPGRADE_IN_PROGRESS>
			RewriteRule ^.*\.(cfm|cfml|cfs|cfc)(/.*)?$ /upgrade-in-progress.html [L]
		</IfDefine>
	</IfModule>
	
</VirtualHost>
```

If the / (root path) does not default to index.cfm and you do NOT want it to display the upgrade status, change the RewriteRule to:

```apache
RewriteRule ^(.+\.cf[msc])(/.*)?$ /upgrade-in-progress.html [L]
```

## Diligence is Key for Security!

You must ensure that every Lucee site on your server is configured to display the upgrade status page when LUCEE_UPGRADE_IN_PROGRESS is defined, otherwise raw Lucee source code is exposed due to temporary lack of AJP/Tomcat/Lucee proxying.

So, yes there is a small amount of risk, but it is mitigated by the usually short duration of the Lucee upgrade process, and of course ... diligence!

You could also create a script which iterates over all sites and ensures that the RewriteRule has been added to each site's VirtualHost.

Many other techniques were attempted, but failed. Apache configurations are a mind-numbing maze. A global mod_proxy, for example, similar to the AJP proxy, but to a static HTML file, did not work as hoped. That would have been ideal. Global RewriteRule on Lucee URLs also did not work, nor did global 302 redirect.

RewriteURL inside each VirtualHost was the only thing that actually (and amazingly) worked. It had been looking like nothing would work, so it was quite the relief when it finally did!

If you happen to be aware of a much simpler solution than what is presented herein, despite the massive facepalm that would trigger after so many hours of head banging on wall (argh) and the not overly confident conclusion that This Is The Way ... please do share!

## Example `/upgrade-in-progress.html`:

This template does the job for any site, or you can customize the branding, etc, specific to each site. Deploy as you see fit.

When QA testing you can change to: `const numInterval = 1000;`

```html
<!DOCTYPE html>
<html>
<head>
<title>Upgrade In Progress</title>
<script>
window.addEventListener('DOMContentLoaded', function() {
	const numInterval = 60000;
	function checkUpgradeStatus() {
		fetch(window.location.href, {
			method: 'GET',
			cache: 'no-cache'
		})
		.then(response => response.text())
		.then(html => {
			if (!html.includes('Upgrade In Progress')) window.location.reload();
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
- `configure-sites.sh` injects per-VirtualHost includes pointing to:
  - `/opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf`
  - `/opt/lucee/sys/upgrade-in-progress/lucee-404-routing.conf` (root sites only)
- Debian/Ubuntu: updates both HTTPS vhosts (e.g., `domain-ssl.conf`) and HTTP vhosts (`domain.conf`) where present.
- cPanel: writes userdata to BOTH trees, then rebuilds httpd config and gracefully restarts:
  - SSL: `/etc/apache2/conf.d/userdata/ssl/2_4/<user>/<domain>/lucee.conf`
  - STD: `/etc/apache2/conf.d/userdata/std/2_4/<user>/<domain>/lucee.conf`
  - Commands: `/scripts/rebuildhttpdconf` and `/scripts/restartsrv_httpd --graceful`
- Non‑cPanel RHEL path remains a placeholder.

Important: Even with HTTP vhosts configured for upgrade mode, you should maintain a proper 80→443 redirect in normal operation to avoid exposure over HTTP.