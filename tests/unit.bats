#!/usr/bin/env bats
# The shape fab and bt-layer require of a unit, checked here so that a
# mistake in this repository fails on a hosted runner in seconds instead of
# on the build host in minutes.
#
# The rules are bin/layer-lib of buildtasks and share/product.mk of fab: a
# unit carries at least one of plan, overlay, conf and removelist; a conf
# that is not executable is skipped by fab without a word; conf-vars names
# one variable per line and fab refuses anything that is not a variable
# name; the version is a single token the layer manifest can carry.

setup() {
    unit="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "the conf script is executable, or fab would skip it in silence" {
    [ -x "$unit/conf" ]
}

@test "the plan names the server and nothing else" {
    run grep -c '^[a-z0-9]' "$unit/plan"
    [ "$output" = "1" ]
    grep -qx 'redis-server' "$unit/plan"
}

@test "no conf-vars: this conf script reads no build time variable" {
    # fab lets a unit name the variables its conf script reads. This one
    # reads none, and a dead interface is not carried (the same reasoning
    # unit-mariadb records for MYSQL_PASS).
    [ ! -e "$unit/conf-vars" ]
    ! grep -qE '\$\{?(REDIS_PASS|APP_PASS|DB_PASS)' "$unit/conf"
}

@test "the version is one line a layer manifest can carry" {
    [ "$(wc -l < "$unit/version")" -eq 1 ]
    run cat "$unit/version"
    [[ "$output" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
    [ "${#output}" -le 64 ]
}

@test "the version is the version of the newest changelog entry" {
    run head -n 1 "$unit/changelog"
    [ "$output" = "unit-redis-$(cat "$unit/version") (1) keel; urgency=low" ]
}

@test "the overlay ships exactly these files" {
    run bash -c "cd '$unit/overlay' && find . -type f | sort"
    expected="./etc/redis/redis.conf.d/10-keel-bind.conf
./etc/redis/redis.conf.d/20-keel-acl.conf
./usr/lib/inithooks/bin/redispass.py
./usr/lib/inithooks/firstboot.d/35redispass
./usr/lib/inithooks/lib/redis.sh"
    [ "$output" = "$expected" ]
}

@test "the first boot hook and its dialog are executable" {
    [ -x "$unit/overlay/usr/lib/inithooks/firstboot.d/35redispass" ]
    [ -x "$unit/overlay/usr/lib/inithooks/bin/redispass.py" ]
}

@test "no removelist: this component takes nothing out of the image" {
    [ ! -e "$unit/removelist" ]
}

@test "the conf script is POSIX shell, which is what its shebang says" {
    # tests/conf.bats runs it as bash, because that is what kcov can
    # measure. This is the check that bash and dash are running the same
    # language.
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    run shellcheck --shell=sh --severity=error "$unit/conf"
    [ "$status" -eq 0 ]
}

@test "the component writes no password anywhere in the tree it ships" {
    # The one property the whole design rests on: what lands on the machine
    # is a digest. A requirepass line anywhere here would undo it.
    ! grep -rqE '^[[:space:]]*requirepass' "$unit/overlay"
    ! grep -rq 'masterauth' "$unit/overlay"
}
