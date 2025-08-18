# "Upgrade in Progress" for Lucee + Apache

Web-based status notifications during Lucee upgrades are a Catch-22 because Lucee itself is not running during the upgrade. That results in an ugly "503 Service Unavailable" error. While it's true that `ErrorDocument 503` can be customized, that page is only displayed when Lucee is not running.

In actual practice it's safest to keep displaying the "Upgrade in Progress" notification not just until after the upgrade is done, but more importantly until *thorough QA testing* has been completed.

**Apache-level advantages over app-level maintenance mode:**

- **No dependency on Lucee**: Works even when Lucee/Tomcat is completely stopped or broken.
- **Performance**: No application overhead - handled before reaching Lucee
- **Security**: No user or bot interference with QA testing. App-level maintenance mode may also be vulnerable to attacks due to untested app.
- **Reliability**: Cannot fail due to application errors, memory issues, code bugs, etc.

**Implementation:**

When you enable "Upgrade in Progress" mode via the app menu, a status notification is displayed in response to every Lucee-bound request. That applies to *every website on your server* that has been configured for this flip-a-switch style automation.

Users are not redirected to a different page, so the URL does not change. They will see the notice of how the page will automatically refresh when the upgrade is complete. That is implemented by detecting a unique http header via HEAD requests which are more efficient than refreshing the page.

## Other Features

- Toggles `ErrorDocument 404` (if already pointing to Lucee script).

- Toggles `/var/lucee-upgrade-in-progress` (reference that file to pause cron jobs, etc).

- Enables optional custom branding of the "Upgrade in Progress" page per site.

- Efficiently loads end user's requested page after upgrade complete.

- Doesn't require CDN, load balancing, etc.

- Backs up existing files before modifying them.

- Open source!


## Menu Options

1. Get Site Data
2. View/Edit Site Data
3. Configure Apache
4. Begin 'Upgrade in Progress'
5. End 'Upgrade in Progress'


## Requirements

- Apache installed in one of the two main Linux familes (Debian, Ubuntu, Pop!_OS, etc or Fedora, Red Hat, AlmaLinux, Rocky Linux, etc).

- Root or sudo permissions.

- Lucee-related directives found in global Apache config as well as site-specific `.htaccess` will be migrated into `.conf` files and `<VirtualHost>` blocks to enable toggling (also best practice for performance, consistency, security, and manageability).

- Other than the initial option to enter your Lucee install path, the config assumes default Apache paths and proxying of .cf* files to Lucee via http or AJP through Tomcat. However, because it's open source, you can customize if you need to, and pull requests are always welcome!


## Backup Folders

`/opt/lucee/sys/upgrade-in-progress/backups/...`

Backups are created only when a file already exists and is about to be modified or replaced.


## QA Testing

To exclude a site, *before configuring Apache*, remove it from the sites data file via the app menu.

`127.0.0.1` (localhost) is always allowed access by default for admin testing.

Allow other IPs: `/opt/lucee/sys/upgrade-in-progress/ip-allow.conf`


## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kenricashe/lucee-installer/main/lucee/linux/sys/upgrade-in-progress/install.sh | sudo bash
```


## Execute

```bash
sudo /opt/lucee/sys/upgrade-in-progress/menu.sh
```
