#!/usr/bin/env bash
# Can ONE gitignored KEY=value file be both `include`d by GNU make and
# `.`-sourced by sh, with command-line env still winning over it?
#
# This is the shape Nathan proposed. It only works if all three hold:
#   1. make -include reads it
#   2. sh . sources it
#   3. precedence is: command line > file > built-in default
#
# Falsifiable: if `?=` in the Makefile beats the included value, or if make
# chokes on a file sh can read, the single-file idea is dead and the machine
# values need two representations.
set -u
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

cat > "$D/.env" <<'ENV'
MODELS=/srv/from-env-file
OPT=/srv/opt-from-env-file
ENV

cat > "$D/Makefile" <<'MK'
-include .env
MODELS ?= $(HOME)/models
OPT    ?= $(HOME)/.local/opt
show:
	@echo "make sees MODELS=$(MODELS)"
	@echo "make sees OPT=$(OPT)"
MK

cat > "$D/setup.sh" <<'SH'
#!/bin/sh
[ -f .env ] && . ./.env
MODELS="${MODELS:-$HOME/models}"
echo "sh sees MODELS=$MODELS"
SH
chmod +x "$D/setup.sh"

cd "$D"
echo "=== 1. make reads the file ==="
make -s show

echo
echo "=== 2. sh sources the same file ==="
./setup.sh

echo
echo "=== 3. command line overrides the file ==="
make -s show MODELS=/srv/from-command-line | head -1
MODELS=/srv/from-command-line ./setup.sh

echo
echo "=== 4. absent file falls back to the default ==="
rm .env
make -s show | head -1
./setup.sh

echo
echo "=== VERDICT ==="
echo "all four behaved as printed above"
