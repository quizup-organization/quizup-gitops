#!/usr/bin/env bash
#
# Reset des données d'observabilité : purge les stores (Prometheus, Alertmanager,
# Grafana, Loki, Tempo) puis resynchronise la stack via ArgoCD.
#
# EFFACE : métriques (7 j), logs (7 j), traces (7 j), silences Alertmanager et base
# Grafana (dashboards as code + datasources sont rechargés au redémarrage ; l'admin
# local et ses préférences sont réinitialisés). Les secrets scellés, la configuration
# (ConfigMaps, règles Prometheus, dashboards) et les DaemonSets sans volume ne sont
# pas touchés.
#
# Prérequis : kubectl (kubeconfig pointant le cluster) — aucune CLI argocd.
#
# Usage :
#   ./scripts/reset-observability.sh        # demande confirmation
#   ./scripts/reset-observability.sh --yes  # non interactif
#
set -euo pipefail

MONITORING_NS="${MONITORING_NS:-monitoring}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

# Ordre : secrets -> stacks (les PVC des StatefulSets sont recréés par leur
# volumeClaimTemplate, ceux des charts par la sync ArgoCD).
APPS=(
  monitoring-secrets kube-prometheus-stack prometheus-blackbox-exporter
  loki tempo otel-collector alloy monitoring
)

ASSUME_YES="false"
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  ASSUME_YES="true"
fi

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl introuvable" >&2; exit 1; }

if [[ "${ASSUME_YES}" != "true" ]]; then
  warn "Ce script EFFACE les données d'observabilité de ${MONITORING_NS} (métriques, logs, traces, base Grafana)."
  read -r -p "Confirmer ? (tapez 'reset') " answer
  [[ "${answer}" == "reset" ]] || { echo "annulé."; exit 1; }
fi

patch_app() {
  printf '%s' "$2" | kubectl -n "${ARGOCD_NS}" patch application "$1" \
    --type merge --patch-file /dev/stdin >/dev/null
}

autosync_off() { patch_app "$1" '{"spec":{"syncPolicy":null}}'; }
autosync_on()  { patch_app "$1" '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'; }
# Pas de `revision` forcée : les apps Helm sont pinnées par version de chart
# (ex. kube-prometheus-stack 91.4.1) — `main` casserait leur comparaison.
argocd_sync()  { patch_app "$1" '{"operation":{"initiatedBy":{"username":"reset-observability.sh"},"sync":{"prune":true}}}'; }

wait_synced() {
  local app="$1" timeout="${2:-600}" i phase
  for i in $(seq 1 $((timeout / 5))); do
    phase="$(kubectl -n "${ARGOCD_NS}" get application "${app}" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Succeeded) echo "  - ${app} : synced"; return 0 ;;
      Failed|Error) echo "  - ${app} : ${phase}" >&2; return 1 ;;
    esac
    sleep 5
  done
  echo "  - ${app} : timeout" >&2
  return 1
}

wait_ready() {
  # $1 = kind/name, $2 = timeout (s)
  local target="$1" timeout="${2:-900}" i
  for i in $(seq 1 $((timeout / 5))); do
    if kubectl -n "${MONITORING_NS}" rollout status "${target}" --timeout=5s >/dev/null 2>&1; then
      echo "  - ${target} : ready"; return 0
    fi
    sleep 5
  done
  echo "  - ${target} : timeout" >&2
  return 1
}

log "Contexte kubectl : $(kubectl config current-context 2>/dev/null || echo '?')"

log "1/6 Désactivation de l'auto-sync ArgoCD"
for app in "${APPS[@]}"; do
  if autosync_off "${app}"; then echo "  - ${app}"; else warn "ignoré (absent) : ${app}"; fi
done

log "2/6 Arrêt des workloads (les DaemonSets sans volume restent)"
kubectl -n "${MONITORING_NS}" scale statefulset --all --replicas=0
kubectl -n "${MONITORING_NS}" scale deployment --all --replicas=0

log "3/6 Suppression des StatefulSets + PVC (stores vierges)"
kubectl -n "${MONITORING_NS}" delete statefulset --all --ignore-not-found
kubectl -n "${MONITORING_NS}" delete pvc --all --ignore-not-found
kubectl -n "${MONITORING_NS}" delete pod --all --ignore-not-found --wait=true

log "4/6 Reconstruction de la stack (ArgoCD)"
for app in "${APPS[@]}"; do
  argocd_sync "${app}"
  wait_synced "${app}" 600 || true
done

log "5/6 Attente des stores (Prometheus, Alertmanager, Grafana, Loki, Tempo)"
for target in \
  statefulset/prometheus-kube-prometheus-stack-prometheus \
  statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  statefulset/loki \
  statefulset/tempo \
  deployment/kube-prometheus-stack-grafana \
  deployment/otel-collector \
  deployment/loki-gateway; do
  wait_ready "${target}" 900 || true
done

log "6/6 Réactivation de l'auto-sync + vérifications"
for app in "${APPS[@]}"; do
  autosync_on "${app}" && echo "  - ${app}"
done
echo
kubectl -n "${MONITORING_NS}" get pvc
echo
kubectl -n "${MONITORING_NS}" get pods

log "Terminé : stores d'observabilité vierges, stack resynchronisée."
