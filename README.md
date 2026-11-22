# ns8-metabase

[Metabase](https://www.metabase.com/) for [NethServer 8](https://nethserver.github.io/ns8-core/): fast analytics with a friendly interface, to let a company explore its data on its own.

The module runs the open source edition of Metabase with its own PostgreSQL database, publishes it through Traefik and lets the users of an NS8 user domain (OpenLDAP or Active Directory) sign in with their directory password.

Module id: `Metabase`. Images are pinned in `build-images.sh` and updated through reviewed changes.

- [Install](#install)
- [Configure](#configure)
- [Directory login (LDAP / AD)](#directory-login-ldap--ad)
- [Administrator account](#administrator-account)
- [Network, ports and routes](#network-ports-and-routes)
- [Images and services](#images-and-services)
- [Backup and restore](#backup-and-restore)
- [Update and uninstall](#update-and-uninstall)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Testing](#testing)

## Install

```bash
add-module ghcr.io/geniusdynamics/metabase:latest 1
```

The command returns the instance id, for example `Metabase1`. Use the id NS8 returns in the commands below.

## Configure

Open the instance in the NS8 web interface, page **Settings**, or use the API:

```bash
api-cli run configure-module --agent module/Metabase1 --data - <<'EOF'
{
  "host": "metabase.example.org",
  "http2https": true,
  "lets_encrypt": false
}
EOF
```

| Parameter | Required | Type | Description |
|---|---|---|---|
| `host` | yes | string | Host name of the application, like `metabase.domain.org`. It must not be used by another Traefik route. |
| `lets_encrypt` | yes | boolean | Request a valid Let's Encrypt certificate. |
| `http2https` | yes | boolean | Redirect all the HTTP requests to HTTPS. |
| `ldap_domain` | no | string | NS8 user domain whose users can sign in to Metabase. Empty disables the directory login. When omitted the current value is kept. See [Directory login](#directory-login-ldap--ad). |
| `admin_email` | no | string | Email of the first Metabase administrator, used only while Metabase has no account. See [Administrator account](#administrator-account). |
| `admin_password` | no | string | Write-only password of the first administrator, 12 to 72 characters. Never returned. |

Every `configure-module` call restarts the Metabase pod, so Metabase is unavailable for about a minute while it starts again. The first start of a new instance takes longer, because Metabase creates its database tables.

Metabase sends email (password resets, alerts, subscriptions) through the NS8 smarthost: the settings are read from the cluster at each configuration.

### Get the configuration

```bash
api-cli run get-configuration --agent module/Metabase1
```

`get-configuration` returns:

| Field | Description |
|---|---|
| `host`, `http2https`, `lets_encrypt` | The values above. |
| `ldap_domain` | Selected user domain, empty when none. |
| `ldap_active` | `true` when Metabase runs with the directory login of that domain. |
| `ldap_schema` | `rfc2307` (OpenLDAP) or `ad` (Active Directory) for the selected domain. |
| `ldap_error` | Why the selected domain cannot be used now: `ldap_domain_unavailable` (it no longer exists) or `ldap_proxy_unreachable`. Empty otherwise. |
| `ldap_domains` | User domains that can be selected: `name`, `schema`, `available`. |
| `setup_complete` | `true` when Metabase already has an account, `false` while its setup wizard is open, `null` when Metabase does not answer. |
| `admin_pending`, `admin_email` | A first administrator is waiting for Metabase to be ready, and its email. |

It never returns a password: not the administrator's, not the directory bind password.

## Directory login (LDAP / AD)

Metabase supports LDAP authentication in its open source edition. This module connects it to an NS8 user domain, so people sign in with the credentials they already have, without a second password to manage.

### How to enable it

1. Create an OpenLDAP or Active Directory user domain in **Domains and users**, and add the users. Every user who has to sign in needs an **email address** in the directory.
2. Open the Metabase instance, page **Settings**, section **Directory login (LDAP / AD)**, pick the user domain and save. With the API: `{"host": "...", "http2https": true, "lets_encrypt": false, "ldap_domain": "example.org"}`.
3. Metabase restarts with the directory login on. The page shows which domain is active.

Pick **None** (`"ldap_domain": ""`) to turn it off again. The module then stops setting the LDAP options, so the directory login is off, unless an administrator saved LDAP settings by hand in the Metabase admin screen (see [Update and uninstall](#update-and-uninstall)).

The module asks the cluster to bind the instance to the user domain (the `cluster:accountconsumer` authorization declared by the image), as every NS8 application that uses a directory does. The relation is visible in **Domains and users** and is removed with the domain or the instance.

### How people sign in

The Metabase login page asks for **Username or email address** once the directory login is active. Both work:

| Domain | Username | Also accepted |
|---|---|---|
| OpenLDAP (rfc2307) | `uid` | `mail` |
| Active Directory | `sAMAccountName` | `userPrincipalName`, `mail` |

Metabase creates the account at the first successful sign-in and fills the name from the directory. Later sign-ins refresh the first and last name. A directory entry without an email address cannot sign in. Users that the NS8 directory proxy hides from the user lists (service accounts such as `krbtgt` or `ldapservice`) are excluded.

Things to know:

- The directory is checked first. If the directory knows the login, only the directory password is accepted, even when a local account with the same email exists, and the sign-in then uses that local account. Do not give the local administrator the email of a directory user.
- If the directory cannot be reached, Metabase falls back to local accounts. The local administrator keeps working in every case.
- An account that someone deactivates in Metabase stays deactivated, whatever the directory says.
- Accounts are created only after the first administrator exists (see below). Before that Metabase refuses to create directory users.

### Settings the module renders

Metabase reads its LDAP settings from `MB_LDAP_*` environment variables (open source edition, version pinned in `build-images.sh`, see the [Metabase environment variables](https://www.metabase.com/docs/latest/configuring-metabase/environment-variables) and the [LDAP documentation](https://www.metabase.com/docs/latest/people-and-groups/google-and-ldap)). Environment variables take precedence over the Metabase admin screen, so the LDAP form of the admin screen is read-only while the module manages the directory login.

Each time the Metabase container starts, `discover-ldap` (an `ExecStartPre` of `metabase-app.service`) reads the domain from the NS8 LDAP proxy and writes `state/ldap.env`, mode `0600`, which is passed to the container with `--env-file`:

| Variable | Value |
|---|---|
| `MB_LDAP_ENABLED` | `true` (`false` while the selected domain is not available) |
| `MB_LDAP_HOST` / `MB_LDAP_PORT` | `accountprovider` (the node loopback seen from the pod) and the port of the LDAP proxy for the domain |
| `MB_LDAP_SECURITY` | `none`: the proxy listens in clear text on the node loopback only and handles the connection to the account provider itself |
| `MB_LDAP_BIND_DN` / `MB_LDAP_PASSWORD` | The read-only account of the domain, from the proxy |
| `MB_LDAP_USER_BASE` | Base DN of the domain, searched recursively |
| `MB_LDAP_USER_FILTER` | OpenLDAP: `(&(objectClass=posixAccount)(mail=*)(\|(uid={login})(mail={login})))`<br>Active Directory: `(&(objectClass=user)(objectCategory=person)(mail=*)(\|(sAMAccountName={login})(userPrincipalName={login})(mail={login})))`<br>each followed by the exclusion of the hidden service accounts |
| `MB_LDAP_ATTRIBUTE_EMAIL` / `_FIRSTNAME` / `_LASTNAME` | `mail`, `givenName`, `sn` |
| `MB_LDAP_GROUP_SYNC` | `false` |

When the module has no domain, the file is empty and nothing is overridden. When the domain disappears the file contains only `MB_LDAP_ENABLED=false`.

The bind password is never in the command line, in Redis (`state/environment` holds the domain name only), in the logs or in `get-configuration`. It stays in the LDAP proxy and in `state/ldap.env`, which is not part of the backup because it is rebuilt at each start.

### User domain changes

When the selected domain is removed, created again or changes its configuration, the NS8 core emits `user-domain-changed` (or `ldap-provider-changed` when an external account provider is added or removed). The module reacts by binding the domain again if needed and restarting the Metabase application, which renders the settings again. Metabase and its local accounts stay available; only the directory login follows the domain.

### What is not included

- **Group synchronization and group mapping** are not configured by the module, and the LDAP form of the admin screen is read-only while the module manages the settings, so directory groups are not mapped to Metabase groups. Assign people to groups in Metabase (Admin settings, People).
- **Paid features** of Metabase (Pro and Enterprise plans) are not available with the open source image: SAML and JWT single sign-on, the LDAP group membership filter, synchronization of LDAP user attributes (for example for data sandboxing) and the option to disable the password login. The password login of local accounts therefore always stays available.
- TLS between Metabase and the proxy (`ldaps` or StartTLS) is not used: that connection stays on the node.

## Administrator account

Metabase has no setting for its first administrator. The first person who opens a new instance in the browser completes a **setup wizard** and becomes the administrator.

The module offers an optional alternative on the **Settings** page, section **First administrator** (`admin_email` and `admin_password`): when Metabase is ready, the module calls the same setup endpoint of Metabase once and creates the account, so nobody else can claim the instance.

- It only acts on an instance without accounts. It never changes an existing administrator or password, and `configure-module` refuses these fields once Metabase has accounts. This is why updating an instance installed with version 1.0.0 changes nothing.
- The password is write-only. It waits in `state/admin.env` (mode `0600`) until the account is created, travels in the request body (never in a command line), is then deleted, and is not included in the backup. If Metabase refuses it, for example because it is on its list of common passwords, the file is deleted and the action fails with the field name.
- Leave both fields empty to keep the wizard of Metabase.
- After the first start, manage accounts in Metabase itself: Admin settings, People. People can reset their password with "forgot password", which works because Metabase sends email through the NS8 smarthost.
- To reset a lost administrator password from the node, Metabase provides a `reset-password` command ([documentation](https://www.metabase.com/docs/latest/people-and-groups/managing#resetting-the-admin-password)). In this module it runs in the application container: `runagent -m Metabase1 podman exec metabase-app java -jar /app/metabase.jar reset-password admin@example.org`. It prints a token to use at `/auth/reset_password/<token>`. The automated tests do not exercise this command.

The local administrator and directory users sign in on the same page and can use Metabase side by side.

## Network, ports and routes

- Reserves 1 TCP port on the node (`org.nethserver.tcp-ports-demand=1`). The Metabase container listens on port 3000 inside its pod and the pod publishes it on `127.0.0.1:<TCP_PORT>` only. The web application is reachable through the Traefik route of the configured host name; no port is opened in the firewall.
- The pod can reach the node loopback (`slirp4netns:allow_host_loopback`, host name `accountprovider`), which is how Metabase reaches the NS8 LDAP proxy. Nothing else is exposed.
- Runs rootless.
- Declares these NS8 authorizations: `traefik@node:routeadm` (route management) and `cluster:accountconsumer` (use of user domains).

## Images and services

| Image | Version |
|---|---|
| `docker.io/postgres` | `18.7-alpine3.24` |
| `docker.io/metabase/metabase` | `v0.50.18.1` (open source edition) |

Services (systemd user units of the module): `metabase.service` (the pod), `postgresql-app.service` (database) and `metabase-app.service` (Metabase). Restart them together with `runagent -m Metabase1 systemctl --user restart metabase.service`.

## Backup and restore

The following paths are included in the NS8 backup (`imageroot/etc/state-include.conf`):

- `state/database.env`, `state/metabase-database.env`, `state/metabase.env`: database and application settings;
- `state/passwords.env`: the Metabase encryption key, which protects the credentials of the data sources stored in Metabase. Without it a restored database cannot decrypt them;
- `state/metabase.pg_dump`: a dump of the application database, created by `module-dump-state` before each backup and removed by `module-cleanup-state`;
- `volumes/urandom`.

What the application database holds: questions, dashboards, accounts (including the directory users created at their first sign-in), permissions and the connection details of your data sources. The data sources themselves are not part of the module.

At restore:

- the database dump is loaded into a fresh PostgreSQL volume, then `configure-module` runs again with the saved host name;
- the selected user domain (`LDAP_DOMAIN`) is restored and bound again. If the domain does not exist on the new cluster, the restore still succeeds and the directory login stays off until the domain exists; local accounts work immediately;
- Let's Encrypt is **not** requested at restore, clone or move, because the DNS may not point to the new node yet. Turn it on again in **Settings** when it does;
- the administrator password is never part of a backup, and restoring does not create an administrator: the restored database has its accounts.

Cloning an instance copies its state and database. After a clone, check the host name and the Let's Encrypt setting.

## Update and uninstall

```bash
api-cli run update-module --data '{"module_url":"ghcr.io/geniusdynamics/metabase:latest","instances":["Metabase1"],"force":true}'
remove-module --no-preserve Metabase1
```

Updating from 1.0.0:

- the existing administrator, accounts and data are untouched, and so is the login behavior: with no user domain selected the module writes an empty LDAP settings file, so nothing overrides what Metabase has stored;
- the update grants the `cluster:accountconsumer` authorization, which it reads from the labels of the new image;
- the application restarts once. The pod is created again with access to the node loopback, which the directory login needs;
- if an administrator had saved LDAP settings in the Metabase admin screen, they keep working until a user domain is selected here. While a user domain is selected, the module's settings win.

The Metabase image is pinned. Newer Metabase versions are taken through a reviewed change of `build-images.sh` (Renovate opens the pull request). Metabase migrates its own database at startup, so go back to an older image only from a backup.

## Troubleshooting

Where to look:

```bash
runagent -m Metabase1 podman logs metabase-app          # Metabase log
runagent -m Metabase1 systemctl --user status metabase-app.service
runagent -m Metabase1 sed 's/^\(MB_LDAP_PASSWORD\)=.*/\1=****/' ldap.env   # rendered LDAP settings
api-cli run get-configuration --agent module/Metabase1  # ldap_active, ldap_error, setup_complete
```

| Symptom | Cause and fix |
|---|---|
| The section shows "Directory login is not active" | The domain was removed (`ldap_domain_unavailable`) or its LDAP proxy cannot reach the account provider (`ldap_proxy_unreachable`). Check the domain in **Domains and users** and its account provider. The login starts working again by itself when the domain is available (domain event), or after `systemctl --user restart metabase-app.service`. |
| Saving fails with "The LDAP proxy of this node cannot reach the user domain" | The domain exists but has no reachable proxy port: the account provider is stopped, or a remote AD or LDAP server is unreachable from the node. |
| A directory user gets "Password did not match stored password" | The directory does not know that login as the filter searches it: wrong user name, an entry without `mail`, or a hidden service account. Or the password is wrong. Check that the entry has an email address. |
| A user can sign in with the user name but not with the email address, or the reverse | The attribute is missing or different in the directory: OpenLDAP `uid` and `mail`, Active Directory `sAMAccountName`, `userPrincipalName` and `mail`. |
| `Instance has not been initialized` in the log | Directory users can be created only after the first administrator exists. Create the administrator first (wizard or **First administrator**). |
| `Problem connecting to LDAP server, will fall back to local authentication` in the log | Metabase cannot reach the proxy. Check `ldap.env` (`MB_LDAP_ENABLED=true`, host `accountprovider`), that the pod was created by the current `metabase.service` (restart the services), and the account provider. |
| The bind account of the domain changed | It is read from the proxy at each start. When an account provider is replaced the domain event restarts the application; otherwise restart `metabase-app.service`. |
| The admin screen shows the LDAP settings but cannot save them | Expected while a user domain is selected: environment variables take precedence over the admin screen. Select **None** to hand the settings back. |
| Saving the administrator fails with "Metabase did not become ready in time" | The first start can take several minutes on a slow node. Save again: the same call retries and nothing is lost. |

To check the directory itself from the node, search with `ldapsearch` against `127.0.0.1` on the port `MB_LDAP_PORT` of `ldap.env`, with the bind account `MB_LDAP_BIND_DN` (use `-W` to type the password instead of putting it in the command line).

## FAQ

**Is LDAP a paid feature of Metabase?**
No. LDAP sign-in is in the open source edition. The paid plans add SAML and JWT single sign-on, the LDAP group membership filter, synchronization of LDAP user attributes and the option to disable the password login.

**Can I disable the local password login so only the directory works?**
No: that option is paid-only in Metabase. The local accounts stay available, which also keeps the administrator able to sign in when the directory is down.

**Can directory groups become Metabase groups?**
Not with this module, see [What is not included](#what-is-not-included). Create the groups in Metabase and add people to them.

**Does the directory login create a user for everybody in the domain?**
No. The account is created when a person signs in for the first time. People are not copied in advance and are not removed when they leave the directory: deactivate their account in Metabase, or remove them from the directory so that their password stops working.

**Can two NS8 user domains be used?**
One per instance. Install a second instance for another domain.

**What does Metabase read from the directory?**
Only what the filter and mapping read: user name, `mail`, `givenName` and `sn`, plus the password the person types, which is checked by binding to the directory.

**Why does the Settings page not create my administrator?**
The module acts only while Metabase has no account. Once the wizard was completed, or a first administrator exists, manage accounts in Metabase.

## Testing

Continuous integration:

- `Publish images` builds the module image on every push.
- `Test module` installs the image on a QEMU NS8 node and runs the Robot Framework suite in `tests/`. It runs after `Publish images` succeeds on `dev` and on `main`.
- `Build API JSON Schema docs` and the security scan run alongside.

The suite installs the module, configures a host name and checks that the web application answers through Traefik. It then:

- creates the first administrator from the configuration and checks that the password is never returned, logged or left on disk, and that invalid or late administrator settings are refused;
- installs an OpenLDAP user domain, selects it, and checks that a directory user signs in with the user name and with the email address, that a wrong password is refused, that the local administrator still signs in, that the bind password stays in a `0600` file, and that clearing the domain, or removing it from the node, turns the directory login off without affecting the local accounts;
- installs the last release (1.0.0), creates an administrator, updates to the tested image and checks that the administrator and the login behavior are unchanged (skipped when the release image cannot be installed on the test node).

Run it locally with the NS8 standard infrastructure described in the [ns8-github-actions README](https://github.com/NethServer/ns8-github-actions/blob/v1/README.md#running-tests-locally). The user interface lint and build run with `yarn lint` and `yarn build` in `ui/`.

## Upstream

Application documentation: https://www.metabase.com/docs/latest/ (LDAP: https://www.metabase.com/docs/latest/people-and-groups/google-and-ldap).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
