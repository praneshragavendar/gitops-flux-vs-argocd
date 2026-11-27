#!/usr/bin/env bash
# End-to-end test: deploy the same app with Flux CD and Argo CD on a kind cluster,
# install Prometheus/Grafana, smoke-test both copies, run a drift test and collect metrics.
# Writes a Markdown report to $REPORT (and to the GitHub job summary when run in Actions).
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL, e.g. https://github.com/owner/repo}"
REPO_BRANCH="${REPO_BRANCH:-main}"
IMAGE="${IMAGE:-ghcr.io/praneshragavendar/mompop-cafe-web:v1.0.0}"
REPORT="${REPORT:-results/ci-report.md}"
mkdir -p "$(dirname "$REPORT")"

log() { echo "::group::$*" 2>/dev/null || true; echo "==> $*"; }
endlog() { echo "::endgroup::" 2>/dev/null || true; }
now() { date +%s; }

# ---------- 1. Build the app image and load it into kind (no registry needed) ----------
log "Build app image"
docker build -t "$IMAGE" app/web
kind load docker-image "$IMAGE" --name gitops
endlog

# ---------- 2. Secrets (never in Git; created out-of-band like in the README) ----------
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

# ---------- 4. Hand the app to both tools at the same moment ----------
log "Start GitOps sync (both tools)"
T0=$(now)
# Flux: same objects `flux bootstrap` would create, but read-only (no token, no commits to the repo)
flux create source git flux-system --url="$REPO_URL" --branch="$REPO_BRANCH" --interval=1m
kubectl apply -f clusters/my-cluster/
# Argo CD: same Application file, pointed at this repo and branch
sed -e "s#repoURL: .*#repoURL: ${REPO_URL}#" -e "s#targetRevision: .*#targetRevision: ${REPO_BRANCH}#" \
  argocd/mompop-cafe.yaml | kubectl apply -f -
endlog

wait_ready() {  # namespace -> echoes seconds since T0 when cafe-web and mysql are available
  local ns=$1 deadline=$(( $(now) + 900 ))
  until kubectl -n "$ns" get deploy cafe-web mysql >/dev/null 2>&1; do
    [ "$(now)" -gt "$deadline" ] && return 1; sleep 5
  done
  kubectl -n "$ns" wait deploy/mysql deploy/cafe-web --for=condition=Available --timeout=15m >/dev/null
  echo $(( $(now) - T0 ))
}

log "Wait for both app copies"
wait_ready mompop-cafe-flux   > /tmp/flux_ready & P1=$!
wait_ready mompop-cafe-argocd > /tmp/argo_ready & P2=$!
wait "$P1"; wait "$P2"
FLUX_READY=$(cat /tmp/flux_ready); ARGO_READY=$(cat /tmp/argo_ready)
flux get kustomizations
kubectl -n argocd get applications.argoproj.io
kubectl get pods -n mompop-cafe-flux -o wide
kubectl get pods -n mompop-cafe-argocd -o wide
endlog

# ---------- 5. Smoke test: the page loads AND the menu comes from MySQL ----------
smoke() {  # port -> "pass"/"fail"
  local port=$1
  for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:${port}/menu.php" | grep -q "Croissant"; then echo pass; return; fi
    sleep 5
  done
  echo fail
}
log "Smoke test both copies"
FLUX_SMOKE=$(smoke 30080); ARGO_SMOKE=$(smoke 30081)
echo "flux=$FLUX_SMOKE argocd=$ARGO_SMOKE"
endlog

# ---------- 6. Monitoring stack (installed by Flux) ----------
log "Wait for Prometheus/Grafana"
kubectl -n flux-system wait kustomization/monitoring-stack --for=condition=Ready --timeout=15m
kubectl -n flux-system wait kustomization/monitoring-config --for=condition=Ready --timeout=10m
kubectl get pods -n monitoring
endlog

# ---------- 7. Drift test: change both copies by hand, time how long each tool takes to undo it ----------
log "Drift test"
kubectl -n mompop-cafe-flux   scale deploy cafe-web --replicas=4
kubectl -n mompop-cafe-argocd scale deploy cafe-web --replicas=4
D0=$(now)
drift_fixed() {  # namespace -> seconds until spec.replicas is back to 2 (or "not reverted")
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
endlog

# ---------- 9. Report ----------
{
  echo "## End-to-end GitOps test: Flux CD vs Argo CD"
  echo
  echo "Cluster: kind (single node) on a GitHub Actions runner. Commit: \`${GITHUB_SHA:-local}\`."
  echo "Numbers come from this run only: a small CI cluster, not a production benchmark."
  echo
  echo "| Check | Flux CD | Argo CD |"
  echo "| --- | --- | --- |"
  echo "| App deployed and healthy (s after hand-off; both started together) | ${FLUX_READY} s | ${ARGO_READY} s |"
  echo "| Smoke test (menu.php served with data from MySQL) | ${FLUX_SMOKE} | ${ARGO_SMOKE} |"
  echo "| Drift correction (cafe-web scaled 2 → 4 by hand) | ${FLUX_DRIFT} | ${ARGO_DRIFT} |"
  echo
  echo "Drift note: Argo CD \`selfHeal\` reacts to the change itself; Flux corrects drift on its next"
  echo "reconcile (\`interval: 5m\` in clusters/my-cluster/mompop-cafe.yaml)."
  echo
  echo "$METRICS"
} > "$REPORT"
cat "$REPORT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"

# Fail the job only on real deployment problems (metrics are best-effort)
[ "$FLUX_SMOKE" = "pass" ] && [ "$ARGO_SMOKE" = "pass" ]
