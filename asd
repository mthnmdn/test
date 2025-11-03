#!/usr/bin/env bash
set -euo pipefail

# Cluster adını console URL'den al (örnek: https://console-openshift-console.apps.qwerty.ocp.example.com)
CLUSTER=$(
  oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}' \
  | sed -E 's|https://console-openshift-console\.apps\.([^./]+).*|\1|'
)

echo "cluster,namespace,route,host,tlsTermination,service,pods"

# Sistem namespace'leri hariç tut
for NS in $(oc get ns -o json \
            | jq -r '.items[].metadata.name
                     | select(test("^(kube|openshift)-|^default$")|not)'); do

  # Geçici JSON dosyaları
  ROUTES_JSON=$(mktemp)
  SVCS_JSON=$(mktemp)
  PODS_JSON=$(mktemp)

  oc get route -n "$NS" -o json > "$ROUTES_JSON" 2>/dev/null || echo '{"items":[]}' > "$ROUTES_JSON"
  if [ "$(jq '.items|length' "$ROUTES_JSON")" -eq 0 ]; then
    rm -f "$ROUTES_JSON" "$SVCS_JSON" "$PODS_JSON"
    continue
  fi

  oc get svc  -n "$NS" -o json > "$SVCS_JSON"  2>/dev/null || echo '{"items":[]}' > "$SVCS_JSON"
  oc get pods -n "$NS" -o json > "$PODS_JSON"  2>/dev/null || echo '{"items":[]}' > "$PODS_JSON"

  jq -r \
    --slurpfile svcs "$SVCS_JSON" \
    --slurpfile pods "$PODS_JSON" \
    --arg ns "$NS" \
    --arg cluster "$CLUSTER" '
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
    | ($.spec.host // "-") as $host
    | ($.spec.tls.termination // "none") as $term
    | ([$.spec.to] + ($.spec.alternateBackends // []))[]
    | select(.kind=="Service")
    | .name as $svcname
    | ($svcs[0].items
       | map(select(.metadata.name==$svcname))
       | .[0]) as $svc
    | (if $svc == null then
         [$cluster, $ns, $.metadata.name, $host, $term, $svcname, "-"]
       else
         [$cluster, $ns, $.metadata.name, $host, $term, $svcname, (pods_for($svc))]
       end)
    | @csv
    ' "$ROUTES_JSON"

  rm -f "$ROUTES_JSON" "$SVCS_JSON" "$PODS_JSON"
done
