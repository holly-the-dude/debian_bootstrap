#!/bin/sh
# Download the Library installer without executing it during Debian setup.
set -eu
root=${1:-/target}
repository=https://github.com/holly-the-dude/Library-Creator_x86.git
mkdir -p "$root/root"
if [ -e "$root/root/Library-Creator_x86" ]; then
    logger -t library-clone 'Existing /root/Library-Creator_x86 preserved; no clone or update performed'
    exit 0
fi
if in-target git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=120 clone "$repository" /root/Library-Creator_x86; then
    logger -t library-clone 'Library installer downloaded to /root/Library-Creator_x86; run bootstrap after boot'
else
    logger -t library-clone 'WARNING: Library clone failed; Debian installation will finish. Retry git clone after boot.'
fi
