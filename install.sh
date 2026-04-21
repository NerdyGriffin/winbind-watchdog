#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="winbind-watchdog"

# Build the RPM if it hasn't been built yet
RPM=$(find "$SCRIPT_DIR/rpmbuild/RPMS" -name "${NAME}-*.noarch.rpm" 2>/dev/null | head -1)
if [[ -z "$RPM" ]]; then
    echo "RPM not found, building..."
    make -C "$SCRIPT_DIR" rpm
    RPM=$(find "$SCRIPT_DIR/rpmbuild/RPMS" -name "${NAME}-*.noarch.rpm" | head -1)
fi

echo "Installing $RPM ..."
rpm -Uvh "$RPM"
