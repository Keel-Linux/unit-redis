#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/lib/redis.sh, the logic behind the
# first boot hook 35redispass (decision 0004). Every function is pure:
# nothing here needs a server, root or a network.

bats_require_minimum_version 1.5.0

setup() {
    load ../overlay/usr/lib/inithooks/lib/redis.sh
}

@test "first_value: the first value that is set and is not DEFAULT" {
    [ "$(redis_first_value "" DEFAULT keeper other)" = keeper ]
    [ "$(redis_first_value default keeper)" = keeper ]
    [ "$(redis_first_value Default keeper)" = keeper ]
    [ "$(redis_first_value first second)" = first ]
    run ! redis_first_value "" DEFAULT ""
    run ! redis_first_value
}

@test "admin_user: the account of this component, or the one APP_DB_USER names" {
    [ "$(redis_admin_user)" = admin ]
    [ "$(redis_admin_user "")" = admin ]
    [ "$(redis_admin_user DEFAULT)" = admin ]
    [ "$(redis_admin_user cacheuser)" = cacheuser ]
    REDIS_ADMIN_USER=operator
    [ "$(redis_admin_user)" = operator ]
}

@test "admin_user: a name that would need thought in an ACL rule is refused" {
    run ! redis_admin_user "rm -rf /"
    run ! redis_admin_user "a b"
    run ! redis_admin_user "9lives"
    run ! redis_admin_user "user>pass"
    run ! redis_admin_user "~*"
}

@test "is_user_name: what this component will put in an ACL rule" {
    redis_is_user_name admin
    redis_is_user_name _svc
    redis_is_user_name cache-user
    redis_is_user_name a1
    run ! redis_is_user_name ""
    run ! redis_is_user_name "1a"
    run ! redis_is_user_name "a%"
}

@test "missing_values: DB_PASS only when the description declared none" {
    [ -z "$(redis_missing_values s3cret)" ]
    [ "$(redis_missing_values "")" = DB_PASS ]
    [ "$(redis_missing_values)" = DB_PASS ]
}

@test "password_hash: the SHA-256 Redis wants after a hash sign" {
    # The value below is sha256("SuperSecret123"), which is also what the
    # server computed for the same password when this design was measured.
    run redis_password_hash SuperSecret123
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s' SuperSecret123 | sha256sum | cut -d' ' -f1)" ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "password_hash: the password itself never appears in the digest" {
    run redis_password_hash SuperSecret123
    [[ "$output" != *SuperSecret123* ]]
}

@test "password_hash: an empty password is refused, not hashed" {
    # The digest of the empty string is a perfectly good digest, and a rule
    # built from it would let somebody authenticate with no password.
    run ! redis_password_hash ""
    run ! redis_password_hash
}

@test "password_hash: an answer that is not a digest fails" {
    REDIS_SHA256="echo not-a-digest"
    run ! redis_password_hash s3cret
}

@test "acl_fragment: one rule, with the digest and never the password" {
    hash=$(redis_password_hash s3cret)
    run redis_acl_fragment admin "$hash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"user admin on #$hash ~* &* +@all"* ]]
    [[ "$output" != *s3cret* ]]
}

@test "acl_fragment: the default account is not repeated here" {
    # 20-keel-acl.conf of the overlay is the only place it is decided.
    hash=$(redis_password_hash s3cret)
    run redis_acl_fragment admin "$hash"
    [[ "$output" != *"user default"* ]]
}

@test "acl_fragment: a name or a digest it will not write" {
    hash=$(redis_password_hash s3cret)
    run ! redis_acl_fragment "rm -rf /" "$hash"
    run ! redis_acl_fragment admin "not-a-digest"
    run ! redis_acl_fragment admin ""
    run ! redis_acl_fragment admin "${hash}extra"
    run ! redis_acl_fragment "" "$hash"
}

@test "verify_argv: the client call that proves the password, without it" {
    output=$(redis_verify_argv admin ::1 6379)
    [ "$output" = $'-h\n::1\n-p\n6379\n--user\nadmin\nPING' ]
    [[ "$output" != *s3cret* ]]
}

@test "verify_argv: a bad account, host or port builds nothing" {
    run ! redis_verify_argv "a b" ::1 6379
    run ! redis_verify_argv admin "" 6379
    run ! redis_verify_argv admin ::1 ""
    run ! redis_verify_argv admin ::1 sixthreeseveNnine
    run ! redis_verify_argv admin ::1 0
}

@test "denied_argv: the same client with no account and no password" {
    output=$(redis_denied_argv ::1 6379)
    [ "$output" = $'-h\n::1\n-p\n6379\nGET\nkeel:no-such-key' ]
    [[ "$output" != *--user* ]]
    run ! redis_denied_argv "" 6379
    run ! redis_denied_argv ::1 nope
}

@test "probe_verdict: PONG and nothing else" {
    redis_probe_verdict PONG
    redis_probe_verdict $'PONG\n'
    run ! redis_probe_verdict ""
    run ! redis_probe_verdict "NOPERM User default has no permissions"
    # The trap this function exists for: a wrong password is answered, not
    # signalled, and redis-cli exits 0 either way.
    run ! redis_probe_verdict "AUTH failed: WRONGPASS invalid username-password pair"
}

@test "denied_verdict: NOPERM is the refusal, an answer is not" {
    redis_denied_verdict "NOPERM User default has no permissions to run the 'get' command"
    run ! redis_denied_verdict ""
    run ! redis_denied_verdict "somevalue"
    run ! redis_denied_verdict "OK"
}

@test "wait_ready: succeeds as soon as the command does" {
    REDIS_SLEEP=:
    redis_wait_ready true 1
    redis_wait_ready true 30
    run ! redis_wait_ready false 3
}

@test "wait_ready: the command is run TRIES times before it gives up" {
    REDIS_SLEEP=:
    attempts="$BATS_TEST_TMPDIR/attempts"
    : > "$attempts"
    failing() { echo x >> "$attempts"; return 1; }
    run ! redis_wait_ready failing 4
    [ "$(wc -l < "$attempts")" -eq 4 ]
}

@test "masked: a length, never the password" {
    [ "$(redis_masked "")" = "(none)" ]
    [ "$(redis_masked)" = "(none)" ]
    [ "$(redis_masked s3cret)" = "(6 characters)" ]
    [[ "$(redis_masked s3cret)" != *s3cret* ]]
}

# --------------------------------------------- the fragment as Redis reads it

@test "every line of the rendered fragment is a comment, blank, or a user rule" {
    local hash line n=0
    hash=$(printf '%s' secret | sha256sum | cut -d ' ' -f 1)
    run redis_acl_fragment admin "$hash"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        n=$((n + 1))
        [[ -z "$line" || "$line" == '#'* || "$line" == 'user '* ]] \
            || { echo "line $n is neither a comment nor a rule: $line"; false; }
    done <<< "$output"
    [ "$n" -gt 1 ]
}

@test "redis-server starts with the shipped ACL file and the rendered fragment" {
    command -v redis-server >/dev/null || skip "redis-server is not installed"
    local hash dir="$BATS_TEST_TMPDIR/redis"
    mkdir -p "$dir"
    hash=$(printf '%s' secret | sha256sum | cut -d ' ' -f 1)
    redis_acl_fragment admin "$hash" > "$dir/50-keel-secret.conf"
    {
        echo "port 0"
        echo "unixsocket $dir/redis.sock"
        echo "dir $dir"
        echo "daemonize no"
        echo "logfile \"\""
        echo "include $BATS_TEST_DIRNAME/../overlay/etc/redis/redis.conf.d/20-keel-acl.conf"
        echo "include $dir/50-keel-secret.conf"
    } > "$dir/redis.conf"
    # a configuration Redis refuses makes it exit at once; one it accepts
    # keeps it running until the timeout stops it (status 124)
    run timeout 3 redis-server "$dir/redis.conf"
    echo "$output"
    [ "$status" -eq 124 ]
    [[ "$output" != *"Unresolved Configuration"* ]]
    [[ "$output" != *"FATAL CONFIG FILE ERROR"* ]]
}
