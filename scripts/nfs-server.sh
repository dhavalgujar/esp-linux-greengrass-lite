#!/bin/sh
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
# Start the development NFS server container:
#
#   S31_NFS_CLIENT_NET=192.168.0.0/24 scripts/nfs-server.sh
#
#   S31_NFS_DIR        host directory to export (default: $S31_WORK/nfs)
#   S31_NFS_EXPORT     path the board mounts (default: /srv/nfs/ggl)
#   S31_NFS_CONTAINER  container name (default: s31-ggl-nfs)
#
# The export holds device private keys: restrict it to the board's subnet.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${S31_WORK:-$(dirname -- "$repo")}
client_net=${S31_NFS_CLIENT_NET:?set S31_NFS_CLIENT_NET to the board subnet}
nfs_dir=${S31_NFS_DIR:-$work/nfs}
export_dir=${S31_NFS_EXPORT:-/srv/nfs/ggl}
container=${S31_NFS_CONTAINER:-s31-ggl-nfs}
image=esp32s31-ggl-nfs:local

if docker inspect "$container" >/dev/null 2>&1; then
	echo "$container exists; unmount the board and remove it first" >&2
	exit 1
fi

mkdir -p "$nfs_dir"
docker build -q -f "$repo/nfs-server/Containerfile" -t "$image" \
	"$repo/nfs-server" >/dev/null
docker run -d --name "$container" --privileged --network host \
	-e EXPORT_PATH="$export_dir" -e CLIENT_NET="$client_net" \
	-v "$nfs_dir:$export_dir:rw" "$image" >/dev/null
sleep 2
docker logs "$container"
