#!/usr/bin/env bash
set -euo pipefail

# --- cluster adını console URL'den çıkar ---
CLUSTER=$(
  oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}' \
  | sed -E 's|^https://console-openshift-console\.apps\.([^./]+).*|\1|'
)

# --- jq programını güvenli şekilde bir tmp dosyaya yaz ---
JQ_PROG="$(mktemp)"
cat >"$JQ_PROG" <<'JQ'
def selmatch($sel; $labels):
  (($sel|type=="object") and ($sel|length)>0) and
  ($sel|to_entries|all(. as $kv | ($labels[$kv.key] // null) == $kv.value));

def pods_for($svc):
  (if (($svc.spec.selector // {})|length) == 0
   then ["-"]
   else ($pods[0].items
         | map(select(selmatch($svc.spec.selector; .metadata.labels)))
         | map(.metadata.name))
   end
  | (if length==0 then ["-"] else . end)
  | join(";"));

.items[]
| . as $r
| ($r.spec.host // "-") as $host
| ($r.spec.tls.termination // "none") as $term
| ([$r.spec.to] + ($r.spec.alternateBackends // []))[]
| select(.kind=="Service")
| .name as $svcname
| ($svcs[0].items | map(select(.metadata.name==$svcname)) | .[0]) as $svc
| (if $svc == null then
     [$cluster, $ns, $r.metadata.name, $host, $term, $svcname, "-"]
   else
     [$cluster, $ns, $r.metadata.name, $host, $term, $svcname, (pods_for($svc))]
   end)
| @csv
JQ

# tmp dosyaları temizle
cleanup() {
  rm -f "$JQ_PROG" $ROUTES_JSON 2>/dev/null || true
  rm -f "$SVCS_JSON" "$PODS_JSON" 2>/dev/null || true
}
trap cleanup EXIT

# başlık
echo "cluster,namespace,route,host,tlsTermination,service,pods"

# sistem ns'leri hariç tutup dolaş
oc get ns -o json \
| jq -r '.items[].metadata.name | select(test("^(kube|openshift)-|^default$")|not)' \
| while IFS= read -r NS; do
  ROUTES_JSON="$(mktemp)"; SVCS_JSON="$(mktemp)"; PODS_JSON="$(mktemp)"

  oc get route -n "$NS" -o json >"$ROUTES_JSON" 2>/dev/null || echo '{"items":[]}' >"$ROUTES_JSON"
  if [ "$(jq '.items|length' "$ROUTES_JSON")" -eq 0 ]; then
    rm -f "$ROUTES_JSON" "$SVCS_JSON" "$PODS_JSON"
    continue
  fi

  oc get svc  -n "$NS" -o json >"$SVCS_JSON" 2>/dev/null || echo '{"items":[]}' >"$SVCS_JSON"
  oc get pods -n "$NS" -o json >"$PODS_JSON" 2>/dev/null || echo '{"items":[]}' >"$PODS_JSON"

  jq -r \
    --slurpfile svcs "$SVCS_JSON" \
    --slurpfile pods "$PODS_JSON" \
    --arg ns "$NS" \
    --arg cluster "$CLUSTER" \
    -f "$JQ_PROG" \
    "$ROUTES_JSON"

  rm -f "$ROUTES_JSON" "$SVCS_JSON" "$PODS_JSON"
done
