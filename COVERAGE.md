# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell). The acceptance test of a
component is the layer that consumes it: `keel-redis` builds it, boots it in
LXC and proves the declared secret reaches the server, which is why this
repository does not carry a boot test of its own.

## Measured 2026-09-28

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/lib/redis.sh | tests/redis.bats (20 tests) | 100 percent (56/56) under kcov | every function and every branch |
| overlay/usr/lib/inithooks/firstboot.d/35redispass | tests/hook.bats (18 tests) | 100 percent (31/31) under kcov | every path, including the four failures that matter |
| conf | tests/conf.bats (20 tests) | 100 percent (42/42) under kcov | the include appended once and last, the fragments, the running server on both families, every refusal, the CRLF an INFO reply really carries, the server log a failure prints, and the packaged log file the check must not leave behind |
| overlay/etc/redis/redis.conf.d/\* | tests/conf.bats (2 tests) | not executable | asserted as content: two literal bind addresses and no name, the default account restricted to `+info`, the administrative account published `off`, and no `requirepass` anywhere |
| overlay/usr/lib/inithooks/bin/redispass.py | none | 0 | dialog wrapper, only reached with a terminal attached |

Total over the three measured shell files: **100 percent (129/129)**,
70 bats tests over four files (conf, hook, library, unit shape).
`tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow sets
to 100, the measured number. It is only ever raised (decision 0006).

    $ COVERAGE_THRESHOLD=100 tests/coverage.sh
    kcov line coverage (threshold 100 percent):
     100.00  56/56  redis.sh
     100.00  31/31  35redispass
     100.00  42/42  conf

## What the tests are really about

Three claims, and each of them is a test rather than a comment.

**The declared secret reaches the server.** `secrets.db_password` renders to
`DB_PASS`, the hook turns it into an ACL rule, restarts the server and
connects as a client with that password. A password the server refuses fails
the hook.

**No secret reaches no data.** The same hook asks for a key with no
credentials at all and requires `NOPERM`. A stub server that answers `(nil)`
instead fails the hook, and the same check fails the build in `conf`. Without
this half, "the secret works" would say nothing about whether it was needed.

**The password is never written down.** The fragment the hook writes holds a
SHA-256, the tests grep the whole fragment directory for the password and
require it absent, and the file's mode is asserted to be 0640. The upstream
appliance wrote `requirepass` into a file the package ships world readable,
which is the defect this replaces.

Under all three, two Redis behaviours that every check is shaped around.

**redis-cli exits 0 when the server answers with an error.** One test drives
the hook with a wrong password through a stub that exits 0 and prints
`WRONGPASS`, and requires the hook to fail anyway. A check written on `$?`
would have passed.

**Redis speaks CRLF.** Every line of an `INFO` reply ends `\r\n`, and
redis-cli prints the reply as it came, so a grep anchored with `$` never
matches a whole line. The first build of this component died there. Every
`INFO` stub in `tests/conf.bats` answers in CRLF now, so the whole file
covers it, and one test says so by name.

## What is not measured, and what would change that

`overlay/usr/lib/inithooks/bin/redispass.py` is a Dialog wrapper, reached
only with a terminal attached, and decision 0003 measures Python with pytest
rather than kcov. It is the same file and the same gap `keel-mariadb` records
for `bin/dbpass.py`, with the same blocker: the inithooks fork has no Dialog
stub yet. The hook's use of it is measured here, with a stub script on the
scratch `INITHOOKS_PATH`: the dialog is asked only when a terminal is
attached, a dialog that returns nothing fails, and a dialog that exits
non-zero fails.

The bind and ACL fragments are configuration, not code, so kcov has nothing
to say about them. They are asserted as content instead, by the two tests
named in the table, because the one line the PostgreSQL appliance got wrong
was in a file exactly like these.

## Plan

- pytest coverage of `redispass.py` when the inithooks fork gains a Dialog
  stub, which is the same blocker `keel-mariadb` records.
- Serving Valkey from this component, which README.rst sizes as one variable
  naming the flavour plus the four paths and the service name the scripts
  already read from the environment. Its own issue, with its own tests.
