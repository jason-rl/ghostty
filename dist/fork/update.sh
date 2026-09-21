#!/bin/sh
# Invoked only after AppKit approves termination. Paths are positional arguments.
set -eu
pid=$1
staged=$2
destination=$3
backup=$4
relaunch=$5
while kill -0 "$pid" 2>/dev/null; do sleep 1; done
if [ ! -d "$staged/Contents" ] || [ ! -d "$destination/Contents" ] || [ -e "$backup" ]; then
    exit 1
fi
mv "$destination" "$backup"
if ! mv "$staged" "$destination"; then
    mv "$backup" "$destination"
    exit 1
fi
if [ "$relaunch" = yes ]; then
    if ! /usr/bin/open "$destination"; then
        mv "$destination" "$staged"
        mv "$backup" "$destination"
        /usr/bin/open "$destination"
        exit 1
    fi
fi
# Retain the backup until the next successful launch cleans it up.
