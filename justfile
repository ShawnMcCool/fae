# justfile for Fae — run `just` (or `just --list`) to see all recipes.

# Default recipe: list available recipes in file order.
[private]
default:
    @just --list --unsorted

# Just serve — run the dev server with live reload.
serve:
    mix phx.server

# Just deploy — build, install, and restart the service onto current code.
deploy:
    bin/deploy

# Just build — assemble a production release into _build/prod/rel/fae.
build:
    bin/build

# Just install — install the already-built release as a user systemd service.
install:
    bin/install

# Examples:
#   just ship           # ship the version currently in mix.exs
#   just ship patch     # bump patch then ship
#   just ship minor     # bump minor then ship
#   just ship major     # bump major then ship
#
# Just ship — cut a versioned GitHub release. Optional bump: major | minor | patch.
ship bump="":
    bin/ship {{ bump }}

# Just test — run the test suite (pass extra args, e.g. a path or file:line).
test *args:
    mix test {{ args }}

# Just check — full precommit gate: compile -Werror, deps check, format, test.
check:
    mix precommit

# Just tail — follow the live service logs.
tail:
    journalctl --user -u fae -f

# Just restart — restart the running service.
restart:
    systemctl --user restart fae

# Just status — show the service status.
status:
    systemctl --user status fae
