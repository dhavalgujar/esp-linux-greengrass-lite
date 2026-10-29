#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
set -eu

export_path=${EXPORT_PATH:-/srv/nfs/ggl}
client_net=${CLIENT_NET:?set CLIENT_NET to the board subnet, e.g. 192.168.0.0/24}
# async: ggconfigd commits SQLite transactions synchronously; with a sync
# export each one waits for the server's disk. Acceptable for a development
# root, which may lose its last writes if the server crashes.
export_options=${EXPORT_OPTIONS:-rw,async,no_subtree_check,no_root_squash,insecure}

test -d "$export_path"
mkdir -p /run/rpc_pipefs /run/sendsigs.omit.d /var/lib/nfs/rpc_pipefs
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

printf '%s %s(%s)\n' "$export_path" "$client_net" "$export_options" \
    >/etc/exports

rpcbind -w
exportfs -rav
rpc.nfsd --no-nfs-version 4 8
exec rpc.mountd --foreground --no-nfs-version 4
