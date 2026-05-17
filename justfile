# justfile for Fae — `just --list` to see all recipes.

# Default recipe: list available recipes.
default:
    @just --list

# Examples:
#   just ship           # ship the version currently in mix.exs
#   just ship patch     # bump patch then ship
#   just ship minor     # bump minor then ship
#   just ship major     # bump major then ship
#
# Ship a release. Optional bump: major | minor | patch.
ship bump="":
    bin/ship {{ bump }}

# Build a production release into _build/prod/rel/fae.
build:
    bin/build

# Install the built release as a user systemd service.
install:
    bin/install
