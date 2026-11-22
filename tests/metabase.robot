*** Settings ***
Library    SSHLibrary

*** Variables ***
${HOST}                 metabase.example.org
${OLD_HOST}             metabase-old.example.org
${ADMIN_EMAIL}          mbadmin@ns8-ci.test
${ADMIN_PASSWORD}       Mb-Admin-CI-2026-x
${LDAP_DOMAIN}          mbdir.ns8-ci.test
${LDAP_USER}            mbuser
${LDAP_MAIL}            mbuser@ns8-ci.test
${LDAP_PASSWORD}        Mb-User-CI-2026,x
${ldap_id}              ${EMPTY}
# Last published release: the upgrade test starts from it
${RELEASE_IMAGE}        ghcr.io/geniusdynamics/metabase:1.0.0

*** Test Cases ***
Check if metabase is installed correctly
    ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check if metabase can be configured
    ${rc} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if metabase works as expected
    ${rc} =    Execute Command    bash -c 'for i in $(seq 1 60); do curl -k -s -o /dev/null -f --resolve ${HOST}:443:127.0.0.1 https://${HOST}/ && exit 0; sleep 5; done; exit 1'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Without a directory and an administrator the module changes nothing in Metabase
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${config} =    Get configuration
    Should Be Equal    ${config}[ldap_domain]    ${EMPTY}
    Should Be Equal    ${config}[ldap_active]    ${False}
    Should Be Equal    ${config}[admin_pending]    ${False}
    Should Be Equal    ${config}[setup_complete]    ${False}
    ${size} =    Execute Command    runagent -m ${module_id} stat -c '\%s' ldap.env
    Should Be Equal    ${size}    0
    ${mode} =    Execute Command    runagent -m ${module_id} stat -c '\%a' ldap.env
    Should Be Equal    ${mode}    600
    ${properties} =    Metabase properties
    Should Be Equal    ${properties}[ldap-enabled]    ${False}

Invalid administrator settings are rejected
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"admin_email":"${ADMIN_EMAIL}","admin_password":"short"}'
    ...    return_rc=True    return_stdout=False    return_stderr=False
    Should Not Be Equal As Integers    ${rc}    0
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"admin_email":"not-an-email","admin_password":"${ADMIN_PASSWORD}"}'
    ...    return_rc=True    return_stdout=False    return_stderr=False
    Should Not Be Equal As Integers    ${rc}    0
    ${config} =    Get configuration
    Should Be Equal    ${config}[admin_pending]    ${False}

The first administrator is created from the configuration
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"admin_email":"${ADMIN_EMAIL}","admin_password":"${ADMIN_PASSWORD}"}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${config} =    Get configuration
    Should Be Equal    ${config}[setup_complete]    ${True}
    Should Be Equal    ${config}[admin_pending]    ${False}
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200

The administrator password is write-only and never kept
    ${output}    ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0
    Should Not Contain    ${output}    ${ADMIN_PASSWORD}
    ${exists} =    Execute Command    runagent -m ${module_id} sh -c 'test -e admin.env && echo yes || echo no'
    Should Be Equal    ${exists}    no
    ${files} =    Execute Command    runagent -m ${module_id} sh -c 'grep -rlF -e "${ADMIN_PASSWORD}" .. || true'
    Should Be Empty    ${files}
    ${count} =    Execute Command    ps -eo args | grep -F -e '${ADMIN_PASSWORD}' | grep -vc -e grep
    Should Be Equal As Integers    ${count}    0

An administrator cannot be created once Metabase has accounts
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"admin_email":"other-admin@ns8-ci.test","admin_password":"Other-Admin-CI-2026-x"}'
    ...    return_rc=True    return_stdout=False    return_stderr=False
    Should Not Be Equal As Integers    ${rc}    0
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200
    ${code} =    Metabase login    other-admin@ns8-ci.test    Other-Admin-CI-2026-x
    Should Be Equal    ${code}    401

An unavailable user domain is rejected by validation
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"ldap_domain":"missing.ns8-ci.test"}'
    ...    return_rc=True    return_stdout=False    return_stderr=False
    Should Not Be Equal As Integers    ${rc}    0
    ${config} =    Get configuration
    Should Be Equal    ${config}[ldap_domain]    ${EMPTY}
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200

An OpenLDAP user domain can be created
    ${output}    ${rc} =    Execute Command    add-module ghcr.io/nethserver/openldap:latest 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0
    ${id} =    Evaluate    ast.literal_eval($output)["module_id"]    modules=ast
    Set Suite Variable    ${ldap_id}    ${id}
    ${rc} =    Execute Command    api-cli run module/${ldap_id}/configure-module --data '{"provision":"new-domain","domain":"${LDAP_DOMAIN}","admuser":"admin","admpass":"Mb-Dir-Admin-2026,x"}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    ${rc} =    Execute Command    api-cli run module/${ldap_id}/add-user --data '{"user":"${LDAP_USER}","display_name":"Metabase User","password":"${LDAP_PASSWORD}","locked":false,"groups":[],"mail":"${LDAP_MAIL}"}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0

The user domain is offered by the configuration
    ${config} =    Get configuration
    ${names} =    Evaluate    [d["name"] for d in $config["ldap_domains"]]
    Should Contain    ${names}    ${LDAP_DOMAIN}

Selecting the user domain enables a working LDAP login
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"ldap_domain":"${LDAP_DOMAIN}"}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    ${bound} =    Execute Command    redis-cli HGET cluster/module_domains ${module_id}
    Should Contain    ${bound}    ${LDAP_DOMAIN}
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${config} =    Get configuration
    Should Be Equal    ${config}[ldap_domain]    ${LDAP_DOMAIN}
    Should Be Equal    ${config}[ldap_active]    ${True}
    Should Be Equal    ${config}[ldap_schema]    rfc2307
    ${properties} =    Metabase properties
    Should Be Equal    ${properties}[ldap-enabled]    ${True}
    ${code} =    Metabase login    ${LDAP_USER}    ${LDAP_PASSWORD}
    Should Be Equal    ${code}    200
    ${code} =    Metabase login    ${LDAP_MAIL}    ${LDAP_PASSWORD}
    Should Be Equal    ${code}    200

A wrong directory password is refused
    ${code} =    Metabase login    ${LDAP_USER}    Not-The-Password-1
    Should Be Equal    ${code}    401

The local administrator still signs in next to LDAP
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200

The LDAP bind password stays in a private file
    ${mode} =    Execute Command    runagent -m ${module_id} stat -c '\%a' ldap.env
    Should Be Equal    ${mode}    600
    ${enabled} =    Execute Command    runagent -m ${module_id} grep -c -e '^MB_LDAP_ENABLED=true$' -e '^MB_LDAP_HOST=accountprovider$' -e '^MB_LDAP_SECURITY=none$' ldap.env
    Should Be Equal    ${enabled}    3
    ${filter} =    Execute Command    runagent -m ${module_id} sed -n 's/^MB_LDAP_USER_FILTER=//p' ldap.env
    Should Contain    ${filter}    {login}
    ${output} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    Should Not Contain    ${output}    MB_LDAP_PASSWORD
    ${leaks} =    Execute Command
    ...    runagent -m ${module_id} sh -c 'pw=$(sed -n "s/^MB_LDAP_PASSWORD=//p" ldap.env); test -n "$pw" && (grep -rlF -e "$pw" .. | grep -v "ldap.env$"; ps -eo args | grep -F -e "$pw" | grep -v -e grep; true)'
    Should Be Empty    ${leaks}
    ${count} =    Execute Command
    ...    bash -c 'pw=$(runagent -m ${module_id} sed -n "s/^MB_LDAP_PASSWORD=//p" ldap.env); test -n "$pw" && journalctl --no-pager -q | grep -cF -e "$pw"'
    Should Be Equal As Integers    ${count}    0

Clearing the user domain disables the LDAP login
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"ldap_domain":""}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${bound} =    Execute Command    redis-cli HGET cluster/module_domains ${module_id}
    Should Not Contain    ${bound}    ${LDAP_DOMAIN}
    ${properties} =    Metabase properties
    Should Be Equal    ${properties}[ldap-enabled]    ${False}
    ${code} =    Metabase login    ${LDAP_USER}    ${LDAP_PASSWORD}
    Should Be Equal    ${code}    401
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200

Check if a removed user domain only disables the LDAP login
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${HOST}","http2https":true,"lets_encrypt":false,"ldap_domain":"${LDAP_DOMAIN}"}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${code} =    Metabase login    ${LDAP_USER}    ${LDAP_PASSWORD}
    Should Be Equal    ${code}    200
    ${rc} =    Execute Command    remove-module --no-preserve ${ldap_id}
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    Wait Until Keyword Succeeds    5 min    5 sec    LDAP login is disabled by the domain event
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    ${config} =    Get configuration
    Should Be Equal    ${config}[ldap_active]    ${False}
    Should Not Be Empty    ${config}[ldap_error]
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200

Check if metabase is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${route} =    Execute Command    api-cli run module/traefik1/get-route --data '{"instance":"${module_id}"}'
    Should Not Contain    ${route}    ${HOST}

An upgrade from the last release keeps the administrator and the login behavior
    ${output}    ${rc} =    Execute Command    add-module ${RELEASE_IMAGE} 1
    ...    return_rc=True
    Skip If    ${rc} != 0    The release image ${RELEASE_IMAGE} cannot be installed here
    ${old_id} =    Evaluate    ast.literal_eval($output)["module_id"]    modules=ast
    Set Suite Variable    ${module_id}    ${old_id}
    ${rc} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"host":"${OLD_HOST}","http2https":true,"lets_encrypt":false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    Wait Until Keyword Succeeds    5 min    5 sec    Metabase responds
    # The released module has no administrator setting: use the Metabase setup wizard API
    ${port} =    Execute Command    runagent -m ${module_id} printenv TCP_PORT
    ${token} =    Execute Command
    ...    curl -fsS http://127.0.0.1:${port}/api/session/properties | python3 -c 'import sys,json; print(json.load(sys.stdin)["setup-token"])'
    ${body} =    Evaluate    json.dumps({"token": $token, "user": {"email": $ADMIN_EMAIL, "password": $ADMIN_PASSWORD, "first_name": "Old", "last_name": "Admin"}, "prefs": {"site_name": "Old"}})    modules=json
    ${rc} =    Execute Command
    ...    curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:${port}/api/setup <<'EOF'\n${body}\nEOF
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200
    ${rc} =    Execute Command
    ...    api-cli run update-module --data '{"module_url":"${IMAGE_URL}","instances":["${module_id}"],"force":true}'
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    Wait Until Keyword Succeeds    8 min    5 sec    Metabase responds
    ${code} =    Metabase login    ${ADMIN_EMAIL}    ${ADMIN_PASSWORD}
    Should Be Equal    ${code}    200
    ${config} =    Get configuration
    Should Be Equal    ${config}[ldap_domain]    ${EMPTY}
    Should Be Equal    ${config}[setup_complete]    ${True}
    Should Be Equal    ${config}[admin_pending]    ${False}
    ${size} =    Execute Command    runagent -m ${module_id} stat -c '\%s' ldap.env
    Should Be Equal    ${size}    0
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

*** Keywords ***
Get configuration
    ${output}    ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0
    ${config} =    Evaluate    json.loads($output)    modules=json
    RETURN    ${config}

Metabase port
    ${port} =    Execute Command    runagent -m ${module_id} printenv TCP_PORT
    RETURN    ${port}

Metabase responds
    ${port} =    Metabase port
    ${output}    ${rc} =    Execute Command    curl -fsS --max-time 8 http://127.0.0.1:${port}/api/health
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0
    Should Contain    ${output}    ok

Metabase properties
    ${port} =    Metabase port
    ${output} =    Execute Command    curl -fsS --max-time 8 http://127.0.0.1:${port}/api/session/properties
    ${properties} =    Evaluate    json.loads($output)    modules=json
    RETURN    ${properties}

Metabase login
    [Documentation]    HTTP status of POST /api/session: 200 signed in, 401 refused.
    [Arguments]    ${username}    ${password}
    ${port} =    Metabase port
    ${body} =    Evaluate    json.dumps({"username": $username, "password": $password})    modules=json
    ${code} =    Execute Command
    ...    curl -sS -o /dev/null -w '\%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:${port}/api/session <<'EOF'\n${body}\nEOF
    RETURN    ${code}

LDAP login is disabled by the domain event
    ${content} =    Execute Command    runagent -m ${module_id} cat ldap.env
    Should Be Equal    ${content}    MB_LDAP_ENABLED=false
