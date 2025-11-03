#!/usr/bin/env bash
set -euo pipefail

# Cluster adını console URL'inden çek (örnek: https://console-openshift-console.apps.qwerty.ocp.example.com)
CLUSTER=$(
  oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}' \
  | sed -E 's|https://console-openshift-console\.apps\.([^./]+).*|\1|'
)

# Başlık yaz
echo "cluster,namespace,route,host,tlsTermination,service,pods"

# Sistem namespace'lerini hariç tut, sadece user workload olanlar
oc get ns -o json \
| jq -r '.items[].metadata.name
         | select(test("^(kube|openshift)-|^default$")|not)' \
| xargs -I{} sh -c '
  NS="{}"

  # Namespace içindeki objeleri JSON olarak al
  routes=$(oc get route -n "$NS" -o json 2>/dev/null || echo "{\"items\":[]}")
  [ "$(jq ".items|length" <<<"$routes")" -gt 0 ] || exit 0

  svcs=$(oc get svc -n "$NS" -o json 2>/dev/null || echo "{\"items\":[]}")
  pods=$(oc get pods -n "$NS" -o json 2>/dev/null || echo "{\"items\":[]}")

  jq -r \
    --argjson svcs "$svcs" \
    --argjson pods "$pods" \
    --arg ns "$NS" \
    --arg cluster "'"$CLUSTER"'" \
    '
    # Service selector ile Pod label'ları eşleştir
    def selmatch($sel; $labels):
      (($sel|type=="object") and ($sel|length)>0 and
       ($sel|to_entries|all(. as $kv |
         ($labels[$kv.key] // null) == $kv.value)));

    # Bir service'e ait pod listesini oluştur
    def pods_for($svc):
      (if (($svc.spec.selector // {})|length) == 0
       then ["-"]
       else ($pods.items
             | map(select(selmatch($svc.spec.selector; .metadata.labels)))
             | map(.metadata.name))
       end
      | (if length==0 then ["-"] else . end)
      | join(";"));

    # Route listesini dön
    .items[] as $r
    | ($r.spec.host // "-") as $host
    | ($r.spec.tls.termination // "none") as $term
    | ([$r.spec.to] + ($r.spec.alternateBackends // []))[]
    | select(.kind=="Service")
    | .name as $svcname
    | ($svcs.items
       | map(select(.metadata.name==$svcname))
       | .[0]) as $svc
    | (if $svc == null then
         [$cluster, $ns, $r.metadata.name, $host, $term, $svcname, "-"]
       else
         [$cluster, $ns, $r.metadata.name, $host, $term, $svcname, (pods_for($svc))]
       end)
    | @csv
    ' <<<"$routes"
'
