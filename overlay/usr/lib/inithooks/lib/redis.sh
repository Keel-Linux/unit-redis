#!/bin/bash
# Logic behind firstboot.d/35redispass (decision 0004: logic apart from
# effect). Meant to be sourced. Every function reads its inputs from its
# arguments, prints its result on stdout and returns non-zero instead of
# exiting, so the hook decides what is fatal and a test can exercise every
# branch without a server, a network or root.

# The administrative account this component creates. Redis has no database
# account, so this is an ACL user and not a database role: 20-keel-acl.conf
# publishes it "off", and the first boot turns it on with the password the
# instance description declared.
REDIS_ADMIN_USER="${REDIS_ADMIN_USER:-admin}"
# Where the fragment holding that account is written. It is read after
# 20-keel-acl.conf because Redis sorts the glob of the include and keeps the
# last value it read, so 50 overrides 20.
REDIS_CONF_D="${REDIS_CONF_D:-/etc/redis/redis.conf.d}"
REDIS_SECRET_FRAGMENT="${REDIS_SECRET_FRAGMENT:-50-keel-secret.conf}"
# root writes it, the server reads it as its own user, and nobody else sees
# it. It holds a SHA-256 and never the password, which is the difference
# between this and a requirepass in a world readable /etc/redis/redis.conf.
REDIS_SECRET_MODE="${REDIS_SECRET_MODE:-0640}"
REDIS_SECRET_OWNER="${REDIS_SECRET_OWNER:-root:redis}"
# Where the verification connects. IPv6 first; the server listens on the
# loopback of both families and nowhere else.
REDIS_VERIFY_HOST="${REDIS_VERIFY_HOST:-::1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_SERVICE="${REDIS_SERVICE:-redis-server}"
REDIS_WAIT_TRIES="${REDIS_WAIT_TRIES:-30}"
REDIS_PROBE_ANSWER="${REDIS_PROBE_ANSWER:-PONG}"
# What an ACL user name may be here. Redis allows any string without a
# space, but a name that would need thought inside a "user" line is a name
# this component will not create.
REDIS_USER_RE='^[A-Za-z_][A-Za-z0-9_-]*$'

# redis_first_value VALUE...: the first argument that is set and is not the
# inithooks placeholder DEFAULT; fails when there is none.
redis_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            echo "$value"
            return 0
        fi
    done
    return 1
}

# redis_admin_user [APP_DB_USER]: the account the password belongs to.
# app.options.db_user of the instance description renders to APP_DB_USER,
# so an appliance above this component can name its own account without
# patching the hook.
redis_admin_user() {
    local name
    name=$(redis_first_value "${1-}" "$REDIS_ADMIN_USER")
    redis_is_user_name "$name" || return 1
    echo "$name"
}

# redis_is_user_name NAME: true for a name this component will put in an
# ACL rule
redis_is_user_name() {
    [[ -n "${1-}" ]] && [[ $1 =~ $REDIS_USER_RE ]]
}

# redis_missing_values PASS: the names of the values that need a prompt.
# Empty output means the instance description carried everything, which is
# the headless case the boot test proves.
redis_missing_values() {
    [[ -n "${1-}" ]] || echo DB_PASS
    return 0
}

# redis_password_hash PASS: the SHA-256 of the password, in the lower case
# hexadecimal Redis wants after a '#' in an ACL rule. The password itself is
# never written to disk by this component: an ACL rule takes the digest, so
# the configuration file holds something that cannot be handed to a client.
# Fails on an empty password rather than hashing the empty string, which is
# a digest that would authenticate somebody.
redis_password_hash() {
    local pass=${1-} digest
    [[ -n "$pass" ]] || return 1
    digest=$(printf '%s' "$pass" | ${REDIS_SHA256:-sha256sum} | cut -d' ' -f1)
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    echo "$digest"
}

# redis_acl_fragment USER HASH: the configuration fragment the first boot
# writes, on stdout. Two rules and a comment. The administrative account is
# given every key, every channel and every command, which is what an
# appliance's own account is for; the default account is left exactly as
# 20-keel-acl.conf published it and is not repeated here, so that one file
# stays the only place it is decided.
redis_acl_fragment() {
    local user=${1-} hash=${2-}
    redis_is_user_name "$user" || return 1
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
    cat <<FRAGMENT
# Written by firstboot.d/35redispass from the instance description.
#
# secrets.db_password of the description renders to DB_PASS, and what is
# below is its SHA-256, which is what a Redis ACL rule takes after a '#'.
# The password is not here and is not anywhere on this machine except the
# file the description points at.
#
# This file is the only place the account is declared. Redis refuses a
# user declared twice across configuration files, so 20-keel-acl.conf names
# no administrative account at all and this one names it once. Editing this
# by hand is how an operator would change the account; the password itself
# belongs in the instance description.
user $user on #$hash ~* &* +@all
FRAGMENT
}

# redis_verify_argv USER HOST PORT: the redis-cli call that proves the
# password, one argument per line. The password is not among them: it goes
# to the client through REDISCLI_AUTH in the environment, so it never
# appears in the process list.
redis_verify_argv() {
    local user=$1 host=$2 port=$3
    redis_is_user_name "$user" || return 1
    [[ -n "$host" ]] || return 1
    [[ $port =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "-h" "$host" "-p" "$port" "--user" "$user" "PING"
}

# redis_denied_argv HOST PORT: the redis-cli call that must be refused. No
# user and no password, so it is the default account asking for a key.
redis_denied_argv() {
    local host=$1 port=$2
    [[ -n "$host" ]] || return 1
    [[ $port =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "-h" "$host" "-p" "$port" "GET" "keel:no-such-key"
}

# redis_probe_verdict OUTPUT: what redis-cli printed for the probe.
#
# The output and not the exit code, and this is the one Redis trap worth
# writing down: redis-cli exits 0 when the server answers with an error. A
# wrong password prints "AUTH failed: WRONGPASS ..." and then the command's
# own refusal, and a test that looked at $? would call that a success.
redis_probe_verdict() {
    local answer
    answer=$(printf '%s' "${1-}" | tr -d '[:space:]')
    [[ $answer == "$REDIS_PROBE_ANSWER" ]]
}

# redis_denied_verdict OUTPUT: what redis-cli printed for a key asked
# without a secret. NOPERM is the server refusing the command to the default
# account, which is the other half of what the declared secret means here:
# no secret, no data.
redis_denied_verdict() {
    [[ ${1-} == NOPERM* ]]
}

# redis_wait_ready COMMAND TRIES: run COMMAND until it succeeds, once a
# second, up to TRIES times. COMMAND is given so a test can pass its own.
redis_wait_ready() {
    local command=$1 tries=$2 attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if $command >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        ${REDIS_SLEEP:-sleep} 1
    done
    return 1
}

# redis_masked PASS: what the log may show of a password
redis_masked() {
    if [[ -z "${1-}" ]]; then
        echo "(none)"
    else
        echo "(${#1} characters)"
    fi
}
