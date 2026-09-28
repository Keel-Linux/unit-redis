unit-redis
==========

The Redis component of Keel Linux, as a fab unit: a directory carrying a
``plan``, an ``overlay/`` and an executable ``conf``, which fab resolves and
applies when the recipe being built has it under ``unit.d/`` (``UNIT_DIRS``
in ``share/product.mk``). Compatible with TurnKey Linux appliances.

Unlike ``unit-mariadb`` and ``unit-postgresql``, nothing here was extracted
from the shared tree, because there was nothing to extract:
``turnkeylinux/common`` has no ``conf/redis``, no ``overlays/redis`` and no
``plans/turnkey/redis``. The upstream ``redis`` appliance named its packages
in its own ``plan/main`` and configured the server from its own recipe and
two first boot hooks. So this component is new code, written to the rules the
project arrived at with the other two engines.

Why a repository, and why this name
-----------------------------------

Decision 0006 gives appliances the ``keel-`` prefix and leaves
infrastructure unprefixed. A component is neither: not an appliance, and not
a fork of an upstream repository. ``unit-`` names the artefact in the
vocabulary of the build system that consumes it, and the name after the dash
is the directory under ``unit.d``, which is the name the layer manifest
carries::

    keel-linux/unit-redis   ->   unit.d/redis   ->   units redis@1.0.0

What it carries
---------------

========================================  ===================================
File                                      What it is
========================================  ===================================
``plan``                                  ``redis-server``, which pulls
                                          ``redis-tools`` at its own version
``overlay/etc/redis/redis.conf.d/``       the bind addresses, and who may do
                                          what before any secret exists
``overlay/usr/lib/inithooks/``            the first boot hook, its library
                                          and its dialog
``conf``                                  the include line, and the running
                                          server asked what it is doing
``version``                               the pin ``bt-layer`` records in the
                                          layer manifest
========================================  ===================================

There is no ``conf-vars``: fab lets a unit name the build time variables its
conf script reads, and this one reads none. There is no ``removelist``: this
component takes nothing out of the image.

The bind addresses
------------------

::

    bind ::1 127.0.0.1

Debian ships ``bind 127.0.0.1 -::1``. The dash is Redis's mark for an
optional address: if ``::1`` cannot be bound the server starts anyway and
says nothing, which is a server that answers one family and looks right.
Both are named here without it.

A name is never used, and that is the trap this project has already paid
for. Debian's ``/etc/hosts`` maps ``::1`` to ``ip6-localhost`` and
``ip6-loopback`` and never to ``localhost``, so ``bind localhost`` resolves
to ``127.0.0.1`` alone; the PostgreSQL appliance shipped listening on IPv4
only for exactly that reason (docs/traps.md, "On Debian, ``localhost`` is not
an IPv6 name"). Two literal addresses cannot resolve into something else.

The port is not opened to the network. This component is what an appliance
that needs Redis is built on, and those talk to it from the same machine.
Opening it, saying who may reach it and terminating TLS is a decision the
appliance makes, and the console modes of decision 0013 are where it will be
made.

What the declared secret means here
-----------------------------------

``secrets.db_password`` of the instance description renders to ``DB_PASS``,
the same variable every database hook of this project reads. On MariaDB it
is a database account's password and on PostgreSQL a role's. **Redis has
neither.** Its secret is one of two things: ``requirepass``, which is the
password of the built in ``default`` user, or an ACL user with a password of
its own.

This component uses **an ACL user**, and the account is ``admin``
(``app.options.db_user`` of the description renames it). So the declared
secret is the password of that ACL user, and a client authenticates with a
user name and that password::

    REDISCLI_AUTH=$(cat /etc/keel/secrets/db_password) \
        redis-cli -h ::1 -p 6379 --user admin PING

Two reasons for the ACL user rather than ``requirepass``, and both are
properties an operator can check:

1. **``requirepass`` would also lock ``INFO``.** ``keel inspect`` reads
   ``database.server.role`` from ``INFO replication`` and ``INFO cluster``,
   it never reads a secret to get past a refusal, and a Redis it cannot ask
   is reported as a role it could not infer. An appliance that cannot say it
   is ``standalone`` cannot say it is a ``primary`` or a ``replica`` either,
   and that reading is the seam the replication modes of decision 0013 are
   built on. So the ``default`` account is left able to run one command,
   ``INFO``, with no key and no channel: the three questions inspect asks
   are answered without a secret, and ``GET`` on any key is refused with
   ``NOPERM``.
2. **``requirepass`` lives in a world readable file.** The package ships
   ``/etc/redis/redis.conf`` as ``root:root 0644``, so the upstream
   appliance wrote the Redis password into a file every local account could
   read, and shipped ``turnkey-redis-pw get`` to print it back out. An ACL
   rule takes the **SHA-256** of a password instead of the password, and
   this component writes that digest into
   ``/etc/redis/redis.conf.d/50-keel-secret.conf`` as ``root:redis 0640``.
   The password itself exists on the machine only in the file the
   description points at.

Before the first boot the administrative account is published ``off``, which
cannot authenticate whatever is sent. That is this component's version of
the invalid password hash ``keel-mariadb`` publishes its account with, and
the reason is the same: a layer is published once and reused by every
appliance built on it, so a password chosen at build time would be the same
password everywhere, and a random one would make the layer irreproducible
(brief section 5.4).

One Redis trap is worth stating on its own, because every check in this
component is written around it: **redis-cli exits 0 when the server answers
with an error.** A wrong password prints ``AUTH failed: WRONGPASS ...`` and
then the command's own refusal, and exits 0. So the hook, the conf script
and the appliance's boot test all read the answer and never the exit code.

How configuration is added
--------------------------

Not by editing Debian's ``redis.conf``, beyond one appended line::

    include /etc/redis/redis.conf.d/*.conf

Redis keeps the last value it read for a directive, and its own manual says
to put an ``include`` last when the included file is meant to override. So
the fragments win, the 110 kB conffile keeps every other default and every
comment, and a package upgrade has one line to ask about. An include whose
glob matches nothing is read as nothing rather than as an error, which is
why the conf script checks that the fragments the overlay ships are there.

The fragments are read in the order the glob sorts them, so 10 is the bind,
20 is who may do what, and 50 is the account the first boot writes, which
therefore replaces the one 20 published.

How a recipe consumes it
------------------------

::

    git clone --branch v1.0.0 https://github.com/keel-linux/unit-redis.git \
        $FAB_PATH/products/redis/unit.d/redis
    bt-layer redis --parent core

``bt-layer`` reads ``version``, records ``units redis@1.0.0`` in the layer
manifest, and a child layer built on that one subtracts the component
instead of applying it again. Assembling ``unit.d`` from the pins a recipe
declares is the step decision 0010 names as new code of the project and does
not exist yet: today the clone above is the assembly step, and the layer
manifest is the record of what was applied.

Order in the build
------------------

fab applies every unit overlay, then every unit conf script, then every unit
removelist, after the common overlays, conf scripts and patches and before
the common removelists, the product overlay and the product's own
``conf.d``. So this conf script runs before the recipe's, and
``keel-redis``'s own ``conf.d/main`` checks what it did rather than trusting
it.

No Webmin module
----------------

Debian 13 packages ``webmin-mysql`` and ``webmin-postgresql`` and no
equivalent for Redis. An appliance built on this component gets the Webmin
panel ``core`` carries, with no Redis page in it, and its boot test checks
that the panel answers rather than pretending a module exists.

What is deliberately not here
-----------------------------

The upstream ``redis`` appliance also ships Redis Commander on nginx and
pm2, a landing page, ``turnkey-redis-pw`` and a confconsole plugin that
writes the password to ``/root/redis_password.txt``. None of it is here.
Redis Commander is a web application and belongs with a web stack, the same
argument that keeps Adminer out of ``unit-mariadb``; and a tool whose job is
to print the Redis password out of a configuration file has nothing to print
once the configuration holds a digest.

Also not here: ``redis-sentinel``, which Debian packages beside the server,
and Redis Cluster, which needs no package at all. Both are modes, and modes
are decision 0013's later phases in their own issue.

Valkey
------

Debian 13 also ships ``valkey-server 8.1.1``, the fork made after Redis
changed its licence. Everything this component does is Valkey's too: Valkey
8.1 keeps the ACL vocabulary, the ``include`` semantics, the ``bind`` syntax
and the ``INFO`` sections, so serving both would be a choice of package name
and of the four paths and one service name this component already reads from
its environment, not a second recipe. What it is not is a drop in rename:
the paths differ (``/etc/valkey/valkey.conf``, ``valkey-server.service``,
``valkey-cli``), so the honest shape is one variable naming the flavour,
and that is a change with its own issue rather than a line smuggled in here.

Tests
-----

``tests/coverage.sh`` runs the bats suite under kcov and fails below
``COVERAGE_THRESHOLD``. COVERAGE.md records what is measured and what is
not. The acceptance test of a component is the layer that consumes it:
``keel-redis`` builds it, boots it in LXC and proves the declared secret
reaches the server, which is why this repository carries no boot test of its
own.
