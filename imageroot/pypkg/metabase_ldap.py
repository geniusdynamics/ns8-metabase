# SPDX-License-Identifier: GPL-3.0-or-later
"""LDAP / Active Directory login of Metabase through an NS8 user domain.

Metabase (open source edition, pinned in build-images.sh) reads its LDAP
settings from MB_LDAP_* environment variables, see
metabase/src/metabase/integrations/ldap.clj and docs/configuring-metabase/
environment-variables.md. A setting taken from the environment overrides the
value stored in the Metabase database.

The module keeps only the NAME of the user domain in state/environment
(LDAP_DOMAIN). The bind DN and password of the domain are read from the NS8
Ldapproxy every time Metabase starts and rendered by "discover-ldap" into
state/ldap.env (mode 0600), which is passed to the container with --env-file:
the password is never in argv, in Redis or in get-configuration.

Three states of state/ldap.env:
- LDAP_DOMAIN empty or unset: the file is empty. Nothing overrides the LDAP
  settings an administrator may have saved in Metabase itself (upgrade from
  1.0.0 does not change the login behavior).
- LDAP_DOMAIN set and the domain is reachable: MB_LDAP_* with LDAP enabled.
- LDAP_DOMAIN set but the domain is gone or its Ldapproxy is not reachable:
  MB_LDAP_ENABLED=false. Metabase and its local accounts keep working.
"""
import os
import sys
from pathlib import Path

import agent
from agent.ldapproxy import Ldapproxy

SUPPORTED_SCHEMAS = ("rfc2307", "ad")
# Metabase runs in a rootless pod: Ldapproxy listens on the node loopback,
# which the pod reaches as 10.0.2.2 (slirp4netns allow_host_loopback, see
# metabase.service). "accountprovider" is the --add-host alias of that address.
LDAP_HOST_ALIAS = "accountprovider"


def state_path(name):
    return Path(os.environ.get("AGENT_STATE_DIR", ".")) / name


ENV_NAME = "ldap.env"


class LdapError(ValueError):
    """A request the module refuses, with the i18n key the UI shows for it."""

    def __init__(self, key, message):
        super().__init__(message)
        self.key = key


def configured_domain():
    return os.environ.get("LDAP_DOMAIN", "").strip()


def all_domains():
    """Return {name: schema} of every user domain the Ldapproxy of this node knows."""
    proxy = Ldapproxy()
    names = proxy.get_domains_list()
    return {name: proxy.domains.get(name, {}).get("schema", "") for name in names}


def describe(domain):
    """Ldapproxy entry of a user domain, or None when it has no reachable proxy port."""
    return Ldapproxy().get_domain(domain)


def domain_choices():
    """User domains the admin may pick: [{name, schema, available}], sorted by name."""
    try:
        proxy = Ldapproxy()
        names = proxy.get_domains_list()
    except Exception:
        return []
    choices = []
    for name in sorted(names):
        schema = proxy.domains.get(name, {}).get("schema", "")
        if schema not in SUPPORTED_SCHEMAS:
            continue
        try:
            available = proxy.get_domain(name) is not None
        except Exception:
            available = False
        choices.append({"name": name, "schema": schema, "available": available})
    return choices


def validate(domain):
    """Check the domain a configure-module request selects, without side effects."""
    if not domain:
        return
    try:
        known = all_domains()
    except Exception:
        raise LdapError("ldap_proxy_unreachable", "The LDAP proxy of this node is not reachable")
    if domain not in known:
        raise LdapError("ldap_domain_unavailable", "The selected user domain does not exist")
    if known[domain] not in SUPPORTED_SCHEMAS:
        raise LdapError("ldap_schema_unsupported", "Only OpenLDAP and Active Directory domains can be used")
    try:
        entry = describe(domain)
    except Exception:
        entry = None
    if entry is None:
        raise LdapError("ldap_proxy_unreachable", "The user domain has no reachable LDAP proxy port")


def user_filter(domain, entry):
    """Metabase user filter: sign in with the user name or the email address.

    "{login}" is replaced by Metabase with the escaped text typed in the login
    form. Entries without an email address are left out: Metabase cannot create
    an account for them and fails the login with a server error otherwise.
    Service accounts that the NS8 Ldapproxy hides from the user lists are
    excluded as well.
    """
    hidden = Ldapproxy().get_ldap_users_search_filter_clause(domain) or ""
    if entry["schema"] == "ad":
        return ("(&(objectClass=user)(objectCategory=person)(mail=*)"
                "(|(sAMAccountName={login})(userPrincipalName={login})(mail={login}))" + hidden + ")")
    return ("(&(objectClass=posixAccount)(mail=*)"
            "(|(uid={login})(mail={login}))" + hidden + ")")


def render(domain):
    """MB_LDAP_* values for the container, see the states in the module docstring."""
    if not domain:
        return {}
    try:
        entry = describe(domain)
    except Exception:
        entry = None
    if not entry or entry.get("schema") not in SUPPORTED_SCHEMAS:
        return {"MB_LDAP_ENABLED": "false"}
    values = {
        "MB_LDAP_ENABLED": "true",
        "MB_LDAP_HOST": LDAP_HOST_ALIAS,
        "MB_LDAP_PORT": str(int(entry["port"])),
        # Ldapproxy speaks clear text on the node loopback and handles TLS to
        # the account provider itself
        "MB_LDAP_SECURITY": "none",
        "MB_LDAP_BIND_DN": entry["bind_dn"],
        "MB_LDAP_PASSWORD": entry["bind_password"],
        # searched recursively: one base serves OpenLDAP (ou=People) and AD (any OU)
        "MB_LDAP_USER_BASE": entry["base_dn"],
        "MB_LDAP_USER_FILTER": user_filter(domain, entry),
        "MB_LDAP_ATTRIBUTE_EMAIL": "mail",
        "MB_LDAP_ATTRIBUTE_FIRSTNAME": "givenName",
        "MB_LDAP_ATTRIBUTE_LASTNAME": "sn",
        "MB_LDAP_GROUP_SYNC": "false",
    }
    if any(c in value for value in values.values() for c in "\r\n"):
        # an env file is one KEY=VALUE per line: never let a value add a line
        return {"MB_LDAP_ENABLED": "false"}
    return values


def write_env(values, path=None):
    """Atomically write the env file with mode 0600 from the first byte."""
    path = path or state_path(ENV_NAME)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def discover():
    """ExecStartPre of metabase-app: refresh state/ldap.env. Never stops Metabase from starting."""
    domain = configured_domain()
    path = state_path(ENV_NAME)
    try:
        values = render(domain)
    except Exception as error:  # never print values: they carry the bind password
        print(agent.SD_WARNING + f"LDAP settings not refreshed: {type(error).__name__}", file=sys.stderr)
        if path.exists():
            return
        values = {"MB_LDAP_ENABLED": "false"} if domain else {}
    write_env(values)
    if values.get("MB_LDAP_ENABLED") == "true":
        print(f"LDAP login enabled with user domain {domain}", file=sys.stderr)
    elif domain:
        print(agent.SD_WARNING + f"LDAP login disabled: user domain {domain} is not available",
              file=sys.stderr)
    else:
        print("LDAP login not managed by the module", file=sys.stderr)


def bind(domain, check=True):
    """Bind the module to the user domain (or to none): the cluster then lets it use the proxy."""
    return agent.bind_user_domains([domain] if domain else [], check=check)


def rebind():
    """Bind again the stored user domain, e.g. after restore or clone. Never fails the caller."""
    domain = configured_domain()
    if not domain:
        return
    try:
        if domain in agent.get_bound_domain_list(agent.redis_connect(use_replica=True)):
            return  # nothing to do, and no needless module-domain-changed event
    except Exception:
        pass
    if not agent.bind_user_domains([domain], check=False):
        print(agent.SD_WARNING + f"User domain {domain} could not be bound: LDAP login stays "
              "disabled until the domain is available", file=sys.stderr)


def handle_domain_event():
    """Event handler of user-domain-changed and ldap-provider-changed."""
    import json
    import subprocess

    domain = configured_domain()
    if not domain:
        return
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, TypeError):
        event = {}
    named = list(event.get("domains") or []) + [event.get("domain")]
    if any(named) and domain not in named:
        return  # another domain changed
    # The domain may have been added back after a restore into a cluster without it
    rebind()
    subprocess.run(["systemctl", "--user", "--no-block", "try-restart", "metabase-app.service"],
                   check=False)
