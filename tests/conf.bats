#!/usr/bin/env bats
# The build time conf script, run for real against scratch directories
# (decision 0004). fab runs it inside the chroot as root; here the four paths
# it takes from the environment point into BATS_TEST_TMPDIR, and redis-server
# and redis-cli are PATH stubs, so nothing needs root, a chroot or a server.
#
# What is under test is the three things the script does and the order it
# does them in: the include appended once and last, the fragments the overlay
# must have delivered, and the running server asked on both loopback
# families and asked for a key it must refuse.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    CONF="$ROOT/conf"
    scratch="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$scratch/bin" "$scratch/etc/redis/redis.conf.d"

    export REDIS_CONF="$scratch/etc/redis/redis.conf"
    export REDIS_CONF_D="$scratch/etc/redis/redis.conf.d"
    export REDIS_CHECK_DIR="$scratch/check"
    export CALLS="$scratch/calls"

    # Debian's conffile, shortened to the two lines that matter here: a bind
    # the fragment has to win over, and a commented include example that must
    # not be read as the include this script adds.
    mkdir -p "$scratch/var/log/redis"
    cat > "$REDIS_CONF" <<CONF
# include /path/to/local.conf
bind 127.0.0.1 -::1
protected-mode yes
port 6379
logfile $scratch/var/log/redis/redis-server.log
CONF
    PACKAGED_LOG="$scratch/var/log/redis/redis-server.log"
    # what the component overlay delivers
    cp "$ROOT/overlay/etc/redis/redis.conf.d/10-keel-bind.conf" "$REDIS_CONF_D/"
    cp "$ROOT/overlay/etc/redis/redis.conf.d/20-keel-acl.conf" "$REDIS_CONF_D/"

    # The stub opens the packaged log file the way redis does. Redis opens
    # every value its logfile setting is ever given, so the one in the
    # configuration file is created even when --logfile names another, and
    # the check runs as root: that is what left a root owned log in the
    # first layer that booted, and a service that could not start.
    stub redis-server 'echo "redis-server $*" >> "$CALLS"
conf=$1
pidfile=""
packaged=$(sed -n "s/^logfile[[:space:]][[:space:]]*//p" "$conf" | tail -1)
[ -n "$packaged" ] && : >> "$packaged"
while [ $# -gt 0 ]; do
    if [ "$1" = --pidfile ]; then pidfile=$2; fi
    shift
done
if [ -n "$pidfile" ]; then sleep 60 & echo $! > "$pidfile"; echo "started-pid $!" >> "$CALLS"; fi
exit 0'
    # The stub answers the way a real server does, which here means CRLF:
    # every line of an INFO reply ends "\r\n" and redis-cli prints the
    # reply as it came. The first build of this component failed because
    # the check was anchored with a dollar and the stub of the day was not
    # faithful about it, so this is the shape every INFO stub below has.
    stub redis-cli 'echo "redis-cli $*" >> "$CALLS"
case " $* " in
  *" INFO server "*|*" INFO server") printf "# Server\r\nredis_version:8.0.2\r\ntcp_port:6379\r\n" ;;
  *" GET "*) echo "NOPERM User default has no permissions to run the '"'"'get'"'"' command" ;;
esac
exit 0'
    PATH="$scratch/bin:$PATH"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$scratch/bin/$1"
    chmod +x "$scratch/bin/$1"
}

run_conf() {
    # bash and not sh, because that is the shell kcov can measure.
    # tests/unit.bats is where the script is checked to be POSIX shell.
    run bash "$CONF"
}

@test "the include is appended, once, and is the last line of the file" {
    run_conf
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$REDIS_CONF")" = "include $REDIS_CONF_D/*.conf" ]
    [ "$(grep -cxF "include $REDIS_CONF_D/*.conf" "$REDIS_CONF")" -eq 1 ]
}

@test "the packaged conffile keeps every line it had" {
    before=$(cat "$REDIS_CONF")
    run_conf
    [ "$status" -eq 0 ]
    [[ "$(cat "$REDIS_CONF")" == "$before"* ]]
    grep -qx 'bind 127.0.0.1 -::1' "$REDIS_CONF"
    grep -qx '# include /path/to/local.conf' "$REDIS_CONF"
}

@test "a second run over the same tree changes nothing and still passes" {
    run_conf
    [ "$status" -eq 0 ]
    first=$(cat "$REDIS_CONF")
    run_conf
    [ "$status" -eq 0 ]
    [ "$(cat "$REDIS_CONF")" = "$first" ]
    [ "$(grep -cxF "include $REDIS_CONF_D/*.conf" "$REDIS_CONF")" -eq 1 ]
}

@test "an include that is present but not last is a failure, not a pass" {
    printf 'include %s/*.conf\nbind 127.0.0.1\n' "$REDIS_CONF_D" >> "$REDIS_CONF"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not end with"* ]]
    [[ "$output" == *"so a fragment would not win"* ]]
}

@test "the running server is asked on both loopback families, at literal addresses" {
    run_conf
    [ "$status" -eq 0 ]
    grep -q -- "redis-cli -h ::1 -p 6379 INFO server" "$CALLS"
    grep -q -- "redis-cli -h 127.0.0.1 -p 6379 INFO server" "$CALLS"
    [[ "$output" == *"Redis answers INFO on [::1]:6379"* ]]
}

@test "the server is started from the file the image will use" {
    run_conf
    [ "$status" -eq 0 ]
    grep -q -- "redis-server $REDIS_CONF " "$CALLS"
}

@test "the check writes no snapshot and leaves no directory behind" {
    run_conf
    [ "$status" -eq 0 ]
    grep -q -- "--save " "$CALLS"
    grep -q -- "--dir $REDIS_CHECK_DIR" "$CALLS"
    [ ! -e "$REDIS_CHECK_DIR" ]
}

@test "the server the check started is stopped again" {
    run_conf
    [ "$status" -eq 0 ]
    pid=$(awk '$1 == "started-pid" { print $2 }' "$CALLS")
    [ -n "$pid" ]
    # the process the pid file named is gone, and so is the pid file
    run ! kill -0 "$pid"
    [ ! -e "$REDIS_CHECK_DIR" ]
}

@test "a server that does not come up fails with the address it was asked on" {
    stub redis-cli 'echo "redis-cli $*" >> "$CALLS"; exit 1'
    export REDIS_TRIES=2
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Redis reported tcp_port:6379 on [::1]:6379"* ]]
    [[ "$output" == *"after 2 tries on [::1]"* ]]
}

@test "a server on one family only fails, which is the trap this exists for" {
    stub redis-cli 'echo "redis-cli $*" >> "$CALLS"
case " $* " in
  *" -h ::1 "*" INFO server"*) printf "# Server\r\ntcp_port:6379\r\n" ;;
  *" -h 127.0.0.1 "*) exit 1 ;;
esac
exit 0'
    export REDIS_TRIES=1
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Redis reported tcp_port:6379 on [127.0.0.1]:6379"* ]]
}

@test "an INFO reply in CRLF is read, which a dollar anchor would not have" {
    # The defect the first build of this component died on. redis-cli
    # prints the reply as it came and Redis speaks CRLF, so the line is
    # "tcp_port:6379\r"; a check anchored with a dollar never matched it,
    # and the message said no Redis answered while the server was up and
    # listening on both families. Measured in the chroot of that build with
    # od -c. The stub above is CRLF for the same reason, so every test in
    # this file covers it; this one says so by name.
    run bash -c 'printf "# Server\r\ntcp_port:6379\r\n" | grep -q "^tcp_port:6379$"'
    [ "$status" -ne 0 ]
    run bash -c 'printf "# Server\r\ntcp_port:6379\r\n" | tr -d "\r" | grep -qx "tcp_port:6379"'
    [ "$status" -eq 0 ]
    run_conf
    [ "$status" -eq 0 ]
}

@test "a failure carries the server's own log, which the check then removes" {
    stub redis-server 'echo "redis-server $*" >> "$CALLS"
pidfile=""; logfile=""
while [ $# -gt 0 ]; do
    if [ "$1" = --pidfile ]; then pidfile=$2; fi
    if [ "$1" = --logfile ]; then logfile=$2; fi
    shift
done
[ -n "$logfile" ] && echo "1:M Ready to accept connections tcp" > "$logfile"
if [ -n "$pidfile" ]; then sleep 60 & echo $! > "$pidfile"; echo "started-pid $!" >> "$CALLS"; fi
exit 0'
    stub redis-cli 'exit 1'
    export REDIS_TRIES=1
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"the last lines of the server's own log"* ]]
    [[ "$output" == *"Ready to accept connections tcp"* ]]
    [ ! -e "$REDIS_CHECK_DIR" ]
}

@test "redis-server refusing the file fails the build" {
    stub redis-server 'echo "redis-server $*" >> "$CALLS"; exit 1'
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"redis-server refused $REDIS_CONF"* ]]
}

@test "a server that hands a key to a client with no secret fails the build" {
    stub redis-cli 'echo "redis-cli $*" >> "$CALLS"
case " $* " in
  *" INFO server"*) printf "# Server\r\ntcp_port:6379\r\n" ;;
  *" GET "*) echo "(nil)" ;;
esac
exit 0'
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"was answered '(nil)' for GET, not NOPERM"* ]]
}

@test "a missing fragment directory fails before anything is started" {
    rm -rf "$REDIS_CONF_D"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"the component overlay did not arrive"* ]]
    [ ! -f "$CALLS" ]
}

@test "a missing fragment fails by name" {
    rm -f "$REDIS_CONF_D/20-keel-acl.conf"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"20-keel-acl.conf is missing"* ]]
    [ ! -f "$CALLS" ]
}

@test "no redis.conf at all says redis-server is not installed" {
    rm -f "$REDIS_CONF"
    run_conf
    [ "$status" -eq 1 ]
    [[ "$output" == *"redis-server is not installed"* ]]
    [ ! -f "$CALLS" ]
}

@test "the bind fragment names two literal addresses and no name" {
    # The fragment is content, not code, so it is asserted here: this is the
    # one line the PostgreSQL appliance got wrong (docs/traps.md).
    grep -qx 'bind ::1 127.0.0.1' "$REDIS_CONF_D/10-keel-bind.conf"
    ! grep -qE '^bind .*localhost' "$REDIS_CONF_D/10-keel-bind.conf"
    ! grep -qE '^bind .*-::1' "$REDIS_CONF_D/10-keel-bind.conf"
}

@test "the acl fragment declares one user, and it is not the administrative one" {
    # Redis refuses a user declared twice across configuration files, so the
    # administrative account cannot be published here and turned on later:
    # it is declared once, at the first boot, or not at all.
    grep -qx 'user default on nopass +info' "$REDIS_CONF_D/20-keel-acl.conf"
    [ "$(grep -c '^user ' "$REDIS_CONF_D/20-keel-acl.conf")" -eq 1 ]
    ! grep -qE '^user admin' "$REDIS_CONF_D/20-keel-acl.conf"
    ! grep -qE '^requirepass' "$REDIS_CONF_D/20-keel-acl.conf"
    ! grep -qE '^user default .*\+@all' "$REDIS_CONF_D/20-keel-acl.conf"
}

@test "no account is declared twice, which Redis refuses outright" {
    # The failure this pair of tests exists for, measured on a booted
    # appliance: "Error in user declaration 'admin': Duplicate user found.
    # A user can only be defined once in config files". The build time
    # fragment and the one the first boot writes may not name the same
    # account, and only the first boot names one.
    source "$ROOT/overlay/usr/lib/inithooks/lib/redis.sh"
    hash=$(redis_password_hash s3cret)
    redis_acl_fragment admin "$hash" > "$REDIS_CONF_D/50-keel-secret.conf"
    run bash -c "cat '$REDIS_CONF_D'/*.conf | grep '^user ' | awk '{print \$2}' | sort | uniq -d"
    [ -z "$output" ]
}

@test "the empty packaged log file the check creates is taken away again" {
    # Redis opens every value its logfile setting is ever given, and the
    # check runs as root, so the packaged /var/log/redis/redis-server.log
    # is created owned by root in a directory the redis user owns. The
    # service then cannot start: "Can't open the log file: Permission
    # denied", measured on the first layer that booted.
    run_conf
    [ "$status" -eq 0 ]
    grep -q -- "--logfile $REDIS_CHECK_DIR" "$CALLS"
    [ ! -e "$PACKAGED_LOG" ]
}

@test "a packaged log file with something in it is left alone" {
    echo "a line somebody may want" > "$PACKAGED_LOG"
    run_conf
    [ "$status" -eq 0 ]
    [ -s "$PACKAGED_LOG" ]
    grep -qx "a line somebody may want" "$PACKAGED_LOG"
}
