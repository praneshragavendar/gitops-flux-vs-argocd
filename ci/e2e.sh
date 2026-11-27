#!/usr/bin/env bash
# End-to-end test on a kind cluster (1 control plane + 2 workers):
# deploy three apps (static, PHP+MySQL, Java) with BOTH Flux CD and Argo CD,
# install Prometheus/Grafana, smoke-test all six copies, run a drift test and collect metrics.
# Writes a Markdown report to $REPORT (and to the GitHub job summary when run in Actions).
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL, e.g. https://github.com/owner/repo}"
REPO_BRANCH="${REPO_BRANCH:-main}"
OWNER="${OWNER:-praneshragavendar}"
REPORT="${REPORT:-results/ci-report.md}"
mkdir -p "$(dirname "$REPORT")"

log() { echo "::group::$*" 2>/dev/null || true; echo "==> $*"; }
endlog() { echo "::endgroup::" 2>/dev/null || true; }
now() { date +%s; }

# app name | build context | image name | NodePort (Flux) | NodePort (Argo CD) | text the page must contain
APPS=(
  "mompop-cafe|app/web|mompop-cafe-web|30080|30081|Croissant|/menu.php"
  "cafe-static|app/static|cafe-static-web|30090|30091|Mom &amp; Pop|/"
  "java-app|app/java|java-app|30092|30093|Hello from the Java app|/"
)

# ---------- 1. Cluster info + build all images and load them into kind ----------
log "Cluster nodes"
kubectl get nodes -o wide
endlog

log "Build app images"
for entry in "${APPS[@]}"; do
  IFS='|' read -r name ctx image _ _ _ _ <<< "$entry"
  tag="ghcr.io/${OWNER}/${image}:v1.0.0"
  docker build -t "$tag" "$ctx"
  kind load docker-image "$tag" --name gitops
done
endlog

# ---------- 2. Secrets for the PHP + MySQL app (never in Git) ----------
log "Create namespaces and Secrets"
for ns in mompop-cafe-flux mompop-cafe-argocd; do
  kubectl create namespace "$ns"
  kubectl -n "$ns" create secret generic cafe-db-secret \
    --from-literal=root-password="$(openssl rand -hex 16)" \
    --from-literal=app-password="$(openssl rand -hex 16)"
done
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -hex 16)"
endlog

# ---------- 3. Install both GitOps tools ----------
log "Install Flux"
flux install
endlog

log "Install Argo CD"
kubectl create namespace argocd
# --server-side: the Argo CD CRDs are too large for client-side apply annotations
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
endlog

# ---------- 4. Hand all apps to both tools at the same moment ----------
log "Start GitOps sync (both tools)"
T0=$(now)
# Flux: same objects `flux bootstrap` would create, but read-only (no token, no commits to the repo)
flux create source git flux-system --url="$REPO_URL" --branch="$REPO_BRANCH" --interval=1m
kubectl apply -f clusters/my-cluster/
# Argo CD: the Application files, pointed at this repo and branch
for app in argocd/*.yaml; do
  sed -e "s#repoURL: .*#repoURL: ${REPO_URL}#" -e "s#targetRevision: .*#targetRevision: ${REPO_BRANCH}#" \
    "$app" | kubectl apply -f -
done
endlog

wait_ready() {  # namespace deployment... -> echoes seconds since T0 when all are available
  local ns=$1; shift
  local deadline=$(( $(now) + 900 ))
  until kubectl -n "$ns" get deploy "$@" >/dev/null 2>&1; do
    [ "$(now)" -gt "$deadline" ] && { echo "timeout"; return 1; }
    sleep 5
  done
  for d in "$@"; do
    kubectl -n "$ns" wait "deploy/$d" --for=condition=Available --timeout=15m >/dev/null
  done
  echo $(( $(now) - T0 ))
}

log "Wait for all six app copies"
PIDS=()
for entry in "${APPS[@]}"; do
  IFS='|' read -r name _ _ _ _ _ _ <<< "$entry"
  deps="$name"; [ "$name" = "mompop-cafe" ] && deps="mysql cafe-web"
  for tool in flux argocd; do
    # shellcheck disable=SC2086
    wait_ready "${name}-${tool}" $deps > "/tmp/ready_${name}_${tool}" & PIDS+=($!)
  done
done
for p in "${PIDS[@]}"; do wait "$p"; done
flux get kustomizations
kubectl -n argocd get applications.argoproj.io
kubectl get pods -A -o wide | grep -E "mompop|cafe-static|java-app"
endlog

# ---------- 5. Smoke test every copy ----------
smoke() {  # port path text -> pass/fail
  local port=$1 path=$2 text=$3
  for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:${port}${path}" | grep -qF "$text"; then echo pass; return; fi
    sleep 5
  done
  echo fail
}
log "Smoke test all copies"
ALL_PASS=true
ROWS=""
for entry in "${APPS[@]}"; do
  IFS='|' read -r name _ _ npf npa text path <<< "$entry"
  sf=$(smoke "$npf" "$path" "$text"); sa=$(smoke "$npa" "$path" "$text")
  [ "$sf" = pass ] && [ "$sa" = pass ] || ALL_PASS=false
  rf=$(cat "/tmp/ready_${name}_flux"); ra=$(cat "/tmp/ready_${name}_argocd")
  ROWS+="| ${name} | ${rf} s / ${sf} | ${ra} s / ${sa} |"$'\n'
  echo "$name: flux=$sf argocd=$sa"
done
endlog

# ---------- 6. Monitoring stack (installed by Flux) ----------
log "Wait for Prometheus/Grafana"
kubectl -n flux-system wait kustomization/monitoring-stack --for=condition=Ready --timeout=15m
kubectl -n flux-system wait kustomization/monitoring-config --for=condition=Ready --timeout=10m
kubectl get pods -n monitoring
endlog

# ---------- 7. Drift test: change the PHP app by hand, time how long each tool takes to undo it ----------
log "Drift test"
kubectl -n mompop-cafe-flux   scale deploy cafe-web --replicas=4
kubectl -n mompop-cafe-argocd scale deploy cafe-web --replicas=4
D0=$(now)
drift_fixed() {  # namespace -> seconds until spec.replicas is back to 2
  local ns=$1 deadline=$(( $(now) + 420 ))
  while [ "$(now)" -lt "$deadline" ]; do
    [ "$(kubectl -n "$ns" get deploy cafe-web -o jsonpath='{.spec.replicas}')" = "2" ] && { echo "$(( $(now) - D0 )) s"; return; }
    sleep 2
  done
  echo "not reverted within 7 min"
}
drift_fixed mompop-cafe-flux   > /tmp/flux_drift & P1=$!
drift_fixed mompop-cafe-argocd > /tmp/argo_drift & P2=$!
wait "$P1"; wait "$P2"
FLUX_DRIFT=$(cat /tmp/flux_drift); ARGO_DRIFT=$(cat /tmp/argo_drift)
echo "flux=$FLUX_DRIFT argocd=$ARGO_DRIFT"
endlog

# ---------- 8. Ask Prometheus for real numbers ----------
log "Collect metrics from Prometheus"
# let Prometheus collect a few minutes of samples for the 5m rate() queries
sleep 120
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/tmp/pf.log 2>&1 &
PF=$!
sleep 5
METRICS=$(python3 ci/prom_query.py http://localhost:9090)
kill "$PF" || true
NODES=$(kubectl get nodes --no-headers | wc -l)
endlog

# ---------- 9. Report ----------
{
  echo "## End-to-end GitOps test: Flux CD vs Argo CD"
  echo
  echo "Cluster: kind with ${NODES} nodes (1 control plane + 2 workers) on a GitHub Actions runner. Commit: \`${GITHUB_SHA:-local}\`."
  echo "Numbers come from this run only: a small CI cluster, not a production benchmark."
  echo
  echo "### Deploy and smoke test (seconds after hand-off / smoke result; all copies started together)"
  echo
  echo "| App | Flux CD | Argo CD |"
  echo "| --- | --- | --- |"
  printf "%s" "$ROWS"
  echo
  echo "### Drift correction (mompop-cafe \`cafe-web\` scaled 2 → 4 by hand)"
  echo
  echo "| Flux CD | Argo CD |"
  echo "| --- | --- |"
  echo "| ${FLUX_DRIFT} | ${ARGO_DRIFT} |"
  echo
  echo "Argo CD \`selfHeal\` reacts to the change itself; Flux corrects drift on its next reconcile (\`interval: 5m\`)."
  echo
  echo "$METRICS"
} > "$REPORT"
cat "$REPORT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"

# Fail the job only on real deployment problems (metrics are best-effort)
[ "$ALL_PASS" = true ]
