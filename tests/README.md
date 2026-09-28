# Tests of the Redis component

Everything here runs on a hosted runner in seconds: no root, no chroot, no
server and no network. `tests/coverage.sh` runs the suite under kcov and
fails below `COVERAGE_THRESHOLD`; the workflow calls it through the
organization's `test-shell.yml` and the check is `tests / coverage`.

    apt-get install bats kcov shellcheck
    COVERAGE_THRESHOLD=100 tests/coverage.sh

| File | What it covers |
| --- | --- |
| `conf.bats` | the build time conf script, run for real against a scratch tree, with `redis-server` and `redis-cli` as PATH stubs. Also the two configuration fragments, asserted as content |
| `hook.bats` | the first boot hook, run for real against a scratch tree, with `systemctl` and `redis-cli` as PATH stubs and a stub dialog on a scratch `INITHOOKS_PATH` whose `lib` is a symlink to the real library, so kcov measures the file the component ships |
| `redis.bats` | the library behind the hook, function by function |
| `unit.bats` | the shape fab and `bt-layer` require of a unit: the executable conf, the plan, the version against the changelog, the overlay's exact file list, and the conf script as POSIX shell under shellcheck |

Two conventions worth knowing before adding a test.

**The stubs answer like a server with `20-keel-acl.conf` in force**, and they
exit 0 even when they refuse, because that is what `redis-cli` does. A stub
that exited non-zero on a refusal would let a check written on `$?` pass, and
that check would be wrong on a real machine.

**The hook is given the scratch paths through the environment**, not through
a copy of itself: `REDIS_CONF_D`, `REDIS_SECRET_OWNER` and `REDIS_SLEEP` are
the defaults of `lib/redis.sh`, and a build sets none of them. The same is
true of `conf`, which reads `REDIS_CONF`, `REDIS_CONF_D`, `REDIS_CHECK_DIR`,
`REDIS_CHECK_HOSTS`, `REDIS_PORT` and `REDIS_TRIES`.

The two tests that need a terminal use `script -qec`, which gives the hook a
pseudo terminal on standard input so `[[ -t 0 ]]` is true. They skip when
util-linux `script` is not installed.
