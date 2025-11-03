#!/usr/bin/env bash
set -euo pipefail

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERR: $1 yok"; exit 1; }; }
require oc
require jq

CONSOLE_URL="$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}' || true)"
[ -n "${CONSOLE_URL:-}" ] || { echo "ERR: consoleURL boş"; exit 1; }
CLUSTER="$(printf '%s' "$CONSOLE_URL" | sed -E 's|^https://console-openshift-console\.apps\.([^./]+).*|\1|')"
[ -n "$CLUSTER" ] || { echo "ERR: cluster adı çıkarılamadı"; exit 1; }

echo "cluster,namespace,route,host,tlsTermination,service,pods"

oc get ns -o json \
| jq -r '.items[].metadata.name | select(test("^(kube|openshift)-|^default$")|not)' \
| while IFS= read -r NS; do
  ROUTES_JSON="$(mktemp)"
  oc get route -n "$NS" -o json >"$ROUTES_JSON" 2>/dev/null || echo '{"items":[]}' >"$ROUTES_JSON"

  jq -r '
    .items[]? as $r
    | ($r.spec.host // "-") as $host
    | ($r.spec.tls.termination // "none") as $term
    | ( ([$r.spec.to] + ($r.spec.alternateBackends // []))
        | map(select(. != null and (.kind // "Service") == "Service"))
        | .[]? ) as $backend
    | [$r.metadata.name, $host, $term, $backend.name]
    | @tsv
  ' "$ROUTES_JSON" \
  | while IFS=$'\t' read -r ROUTE HOST TERM SVC; do
      # Service selector'ını oku (yoksa pods="-")
      SEL_JSON="$(oc get svc "$SVC" -n "$NS" -o json 2>/dev/null | jq -c '.spec.selector // {}')"
      if [ "$SEL_JSON" = "null" ] || [ "$SEL_JSON" = "{}" ]; then
        PODS_STR="-"
      else
        LABELS="$(printf '%s' "$SEL_JSON" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')"
        PODS_STR="$(oc get pods -n "$NS" -l "$LABELS" -o json 2>/dev/null \
                    | jq -r '[.items[].metadata.name] | if length==0 then "-" else join(";") end')"
      fi
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$CLUSTER" "$NS" "$ROUTE" "$HOST" "$TERM" "$SVC" "$PODS_STR"
    done

  rm -f "$ROUTES_JSON"
done

