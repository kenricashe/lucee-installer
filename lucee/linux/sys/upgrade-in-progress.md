# "Upgrade in Progress" Lucee/Apache Server-Wide Status Management

The bash shell script `upgrade-in-progress.sh` is used to begin or end upgrade mode. When in upgrade mode, requests for any Lucee file in every website that has been configured for this (see VirtualHost config below) respond with a static HTML "Upgrade in Progress" notification.

Note how the URL does not change! That way the user can see the upgrade status without being redirected to a different page, and JavaScript is used to automatically refresh the page when the upgrade is complete.

## Typical upgrade command sequence:

```bash
$ sudo /opt/lucee/sys/upgrade-in-progress.sh begin
Enabling lucee-upgrade-in-progress configuration...
Disabling lucee-ajp-and-mod_cfml configuration...
Restarting Apache...
DONE!

$ sudo /opt/lucee/sys/upgrade-in-progress.sh end
Enabling lucee-ajp-and-mod_cfml configuration...
Disabling lucee-upgrade-in-progress configuration...
Restarting Apache...
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

## Example `/upgrade-in-progress.html`:

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