# Major Refactor to Avoid SELinux Management

By simply storing all .conf files under Apache root directory, no need for semanage nor restorecon!

## Todo List

- [x] Replace UPG_DIR with LUCEE_HTTPD_ROOT when copying .conf files

- [x] Don't need normalize_conf_whitespace for auto-generated files e.g. userdata

- [x] All `cp` commands need to be updated to NOT preserve any of the file attributes: `cp --no-preserve=all source_file destination_file`

- [x] Then don't need these:
  - [x] chown
  - [x] chmod
  - [x] restorecon
  - [x] chcon
  - [x] semanage
  - [x] selinux

- [x] Consolidate all file operations in `configure-apache.sh` into `execute_or_simulate`
  - [x] `mv -f`

- [x] begin Lucee proxy

## Replace UPG_DIR with LUCEE_HTTPD_ROOT when copying .conf files

- [x] execute_or_simulate "copy_file"

## Double Check All of File Operations

- [x] cp -f --no-preserve=all

- [x] mv

- [x] sed -i

- [x] tmp/cat/mv change mv to cp/rm

- [x] echo .* >

- [x] cat | tee

- [x] cat >


## These are copied from /opt/lucee/sys/upgrade-in-progress/
- [x] `lucee-detect-upgrade.conf`
  - [x] DETECT_CONF
- [x] `lucee-upgrade-in-progress.conf`
  - [x] `execute_or_simulate "copy_file"`
- [x] `lucee-upgrade-in-progress.html`
  - [x] UPG_HTML

## These are auto-generated:
- [x] `lucee-proxy.conf`
  - [x] `find_active_lucee_proxy_conf_path`
  - [x] `migrate_lucee_proxy_config()`
- [x] `ip-allow.conf`
- [x] `lucee-proxy-for-allowed-ip.conf`
- [x] `site-includes-for-404/${domain}-${port}.conf`
- [x] `${CPANEL_USERDATA_SSL_PATH}/${user}/${domain}/lucee.conf`
- [x] `${CPANEL_USERDATA_STD_PATH}/${user}/${domain}/lucee.conf`

## These are only enabled/disabled:
- [x] `/etc/apache2/sites-enabled/${domain}.conf`
- [x] `/etc/apache2/sites-enabled/${domain}-ssl.conf`

## Hardcoded references that need to be updated:
- [x] `Include /opt/lucee/sys/upgrade-in-progress/lucee-detect-upgrade.conf`
- [x] `Include /opt/lucee/sys/upgrade-in-progress/ip-allow.conf`
- [x] `Include /opt/lucee/sys/upgrade-in-progress/lucee-proxy-for-allowed-ip.conf`
