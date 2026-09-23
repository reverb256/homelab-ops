#!/usr/bin/env bash
# apply-leftovers.sh - apply the proof-ranked downloads leftover manifest.
#
# DRY-RUN BY DEFAULT. This script runs nothing on a timer and deletes nothing
# unless called with `--apply --i-mean-it`. j_kro has not approved the media
# prune; treat this as the one-command step awaiting that word.
#
# Why a wrapper: it resolves the *live* download-client endpoint and credential
# the same way the rest of this repo does (env first, then the cluster secret),
# so the proof does not rot when a Service is recreated.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${MEDIA_DOWNLOADS:-/data/media/downloads}"
KUBECTL="${KUBECTL:-kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml}"
NS="${MEDIA_NS:-media}"

if [ -z "${QBT_USER:-}" ]; then
  eval "$($KUBECTL -n "$NS" get secret qbt-credentials -o json | python3 -c '
import json,sys,base64
d=json.load(sys.stdin)["data"]
for k,v in d.items():
    print("export %s=%s" % (k, repr(base64.b64decode(v).decode())))
')"
fi

if [ -z "${QBT_URL:-}" ]; then
  IP="$($KUBECTL -n "$NS" get svc qbittorrent -o jsonpath='{.spec.clusterIP}')"
  PORT="$($KUBECTL -n "$NS" get svc qbittorrent -o jsonpath='{.spec.ports[0].port}')"
  export QBT_URL="http://${IP}:${PORT}"
fi

exec python3 "$HERE/reclaim-leftovers.py" --root "$ROOT" "$@"
