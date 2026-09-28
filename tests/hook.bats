#!/usr/bin/env bats
# The first boot hook firstboot.d/35redispass (decision 0004): every path it
# takes runs for real against scratch directories, and every command that
# would touch the system (systemctl, redis-cli) is a PATH stub that records
# its arguments. Nothing here needs root, a server or a network.
#
# What these tests are about is what the declared secret means on Redis.
# There is no database account: the secret becomes the password of an ACL
# user, the file the server reads holds its SHA-256 and never the password,
# and a client with no secret is refused every key. Each of those three is a
# test below, and so is the trap under all of them: redis-cli exits 0 when
# the server answers with an error, so a hook that trusted the exit code
# would report a wrong password as a success.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/35redispass"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin" "$scratch/redis.conf.d"
    # the library is the real file, not a copy: kcov measures the one the
    # component ships, and a copy per test would be measured as its own
    # uncovered file
    ln -s "$(cd "$ROOT/overlay/usr/lib/inithooks/lib" && pwd)" "$scratch/inithooks/lib"

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export REDIS_CONF_D="$scratch/redis.conf.d"
    # the hook chowns the fragment to root:redis on a machine; here it is
    # given the user running the tests, so nothing needs root
    export REDIS_SECRET_OWNER="$(id -un):$(id -gn)"
    export REDIS_SLEEP=:

    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF

    stub systemctl 'echo "systemctl $*" >> "$CALLS"'
    # The client, answering the way a server with 20-keel-acl.conf in force
    # does: the administrative account is accepted only with the password
    # the description declared, an unauthenticated key is refused with
    # NOPERM, and INFO is answered to anybody. Every branch exits 0, which
    # is what redis-cli itself does.
    stub redis-cli 'echo "redis-cli $* REDISCLI_AUTH=${REDISCLI_AUTH-}" >> "$CALLS"
case " $* " in
  *" INFO "*) echo "redis_version:8.0.2"; exit 0 ;;
  *" --user "*" PING"*)
      if [ "$REDISCLI_AUTH" = "s3cret-from-the-description" ]; then echo PONG
      else
          echo "AUTH failed: WRONGPASS invalid username-password pair or user is disabled."
          echo "NOPERM User default has no permissions to run the '"'"'ping'"'"' command"
      fi
      exit 0 ;;
  *" GET "*) echo "NOPERM User default has no permissions to run the '"'"'get'"'"' command"; exit 0 ;;
esac
exit 0'
    # The dialog, which only a run with a terminal reaches
    cat > "$scratch/inithooks/bin/redispass.py" <<'DIALOG'
#!/bin/sh
echo "DB_PASS=s3cret-from-the-description"
DIALOG
    chmod +x "$scratch/inithooks/bin/redispass.py"
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

DECLARED_PASS=s3cret-from-the-description
FRAGMENT_NAME=50-keel-secret.conf

# write_conf [EXTRA_LINE...]: the conf a declared description renders to
write_conf() {
    printf 'export DB_PASS=%s\n' "$DECLARED_PASS" > "$INITHOOKS_CONF"
    printf '%s\n' "$@" >> "$INITHOOKS_CONF"
}

@test "the declared password becomes an ACL rule and is proved against the server" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    fragment="$REDIS_CONF_D/$FRAGMENT_NAME"
    [ -f "$fragment" ]
    expected=$(printf '%s' "$DECLARED_PASS" | sha256sum | cut -d' ' -f1)
    grep -qx "user admin on #$expected ~\* &\* +@all" "$fragment"
    grep -q -- "redis-cli -h ::1 -p 6379 --user admin PING" "$CALLS"
    [[ "$output" == *"set from DB_PASS (${#DECLARED_PASS} characters)"* ]]
    [[ "$output" == *"verified on [::1]:6379"* ]]
    [[ "$output" == *"refused every key"* ]]
    [[ "$output" != *"$DECLARED_PASS"* ]]
}

@test "the password never reaches the disk: the fragment holds its digest" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    run ! grep -rq "$DECLARED_PASS" "$REDIS_CONF_D"
}

@test "the password never reaches a command line either" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    # It is in the environment of the recorded call and in no argument.
    grep -q "REDISCLI_AUTH=$DECLARED_PASS" "$CALLS"
    run ! grep -E "^redis-cli .*$DECLARED_PASS.* REDISCLI_AUTH" "$CALLS"
}

@test "the fragment is not readable by everybody" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$REDIS_CONF_D/$FRAGMENT_NAME")" = 640 ]
}

@test "no half written rule is left where a reader could find one" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    run bash -c "ls -A '$REDIS_CONF_D'"
    [ "$output" = "$FRAGMENT_NAME" ]
}

@test "a password the server refuses fails the hook, although redis-cli exits 0" {
    DECLARED_PASS=not-the-one-the-server-has
    write_conf
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the declared password did not reach the server"* ]]
    [[ "$output" == *WRONGPASS* ]]
}

@test "a server that answers something else fails the hook" {
    write_conf
    stub redis-cli 'case " $* " in *" INFO "*) echo redis_version:8.0.2 ;; *) echo surprise ;; esac'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"was answered 'surprise'"* ]]
    [[ "$output" == *"not PONG"* ]]
}

@test "a server that hands a key to a client with no secret fails the hook" {
    write_conf
    stub redis-cli 'case " $* " in
  *" INFO "*) echo redis_version:8.0.2 ;;
  *" --user "*) echo PONG ;;
  *" GET "*) echo "(nil)" ;;
esac'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"hands its data to anyone who can reach it"* ]]
}

@test "nothing declared and no terminal: the hook names the field" {
    printf 'export HOSTNAME=cache\n' > "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS in $INITHOOKS_CONF"* ]]
    [[ "$output" == *"declare secrets.db_password in the instance description"* ]]
    [ ! -f "$CALLS" ]
    [ -z "$(ls -A "$REDIS_CONF_D")" ]
}

@test "no conf at all is the same failure" {
    rm -f "$INITHOOKS_CONF"
    run "$HOOK" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DB_PASS"* ]]
}

@test "nothing declared and a terminal: the dialog is asked" {
    printf 'export HOSTNAME=cache\n' > "$INITHOOKS_CONF"
    # A pseudo terminal on standard input is what [[ -t 0 ]] is looking for
    command -v script >/dev/null || skip "util-linux script is not installed"
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"set from DB_PASS"* ]]
    grep -qx "user admin on #$(printf '%s' "$DECLARED_PASS" | sha256sum | cut -d' ' -f1) ~\* &\* +@all" \
        "$REDIS_CONF_D/$FRAGMENT_NAME"
}

@test "a dialog that gives nothing fails instead of writing a rule" {
    printf 'export HOSTNAME=cache\n' > "$INITHOOKS_CONF"
    command -v script >/dev/null || skip "util-linux script is not installed"
    printf '#!/bin/sh\necho "DB_PASS="\n' > "$scratch/inithooks/bin/redispass.py"
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no password given"* ]]
    [ -z "$(ls -A "$REDIS_CONF_D")" ]
}

@test "a dialog that fails is a failure here, not an empty loop" {
    printf 'export HOSTNAME=cache\n' > "$INITHOOKS_CONF"
    command -v script >/dev/null || skip "util-linux script is not installed"
    printf '#!/bin/sh\nexit 3\n' > "$scratch/inithooks/bin/redispass.py"
    run script -qec "$HOOK" /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"the dialog for DB_PASS failed"* ]]
    [ -z "$(ls -A "$REDIS_CONF_D")" ]
}

@test "APP_DB_USER names the account the password belongs to" {
    write_conf "export APP_DB_USER=cacheuser"
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "^user cacheuser on #" "$REDIS_CONF_D/$FRAGMENT_NAME"
    grep -q -- "--user cacheuser PING" "$CALLS"
}

@test "an account name this component will not create fails before anything runs" {
    write_conf "export APP_DB_USER='rm -rf /'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an account name this component will create"* ]]
    [ ! -f "$CALLS" ]
    [ -z "$(ls -A "$REDIS_CONF_D")" ]
}

@test "the server is restarted after the rule is written, not before" {
    write_conf
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "systemctl restart redis-server.service" ]
    [ "$(sed -n 2p "$CALLS")" = "redis-cli -h ::1 -p 6379 INFO server REDISCLI_AUTH=" ]
}

@test "a server that never answers fails before the client is trusted" {
    write_conf
    stub redis-cli 'echo "redis-cli $*" >> "$CALLS"; exit 1'
    export REDIS_WAIT_TRIES=2
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"redis-server did not answer on [::1]:6379 after 2 tries"* ]]
}

@test "a directory the hook cannot write in fails without a stack trace" {
    write_conf
    export REDIS_CONF_D="$scratch/redis.conf.d/nested/deeper"
    mkdir -p "$scratch/redis.conf.d/nested"
    chmod 500 "$scratch/redis.conf.d/nested"
    run "$HOOK"
    chmod 700 "$scratch/redis.conf.d/nested"
    [ "$status" -ne 0 ]
    [ ! -f "$CALLS" ] || ! grep -q systemctl "$CALLS"
}
