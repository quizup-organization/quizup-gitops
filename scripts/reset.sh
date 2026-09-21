#!/usr/bin/env bash
#
# Reset « base saine » de la prod QuizUp : purge Postgres + Kafka (volumes neufs),
# reconstruit l'infra vierge (7 bases + Kafka vide) puis resynchronise les applications
# (Flyway + seeders idempotents).
#
# EFFACE TOUTES LES DONNÉES (comptes, parties, follows, classements, activité,
# sujets/questions). Les sessions OIDC et les tokens Axon vivent en base -> reconnexion.
#
# Prérequis : kubectl (kubeconfig pointant le cluster) — AUCUNE dépendance à la CLI argocd.
# Les synchronisations ArgoCD sont déclenchées via `spec.operation` (patch kubectl).
#
# Usage :
#   ./scripts/reset.sh            # demande confirmation
#   ./scripts/reset.sh --yes      # non interactif (release / CI)
#
set -euo pipefail

QUIZUP_NS="${QUIZUP_NS:-quizup-prod}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

# app-of-apps + infra + services : on coupe leur auto-sync pendant la purge.
APPS=(
  quizup-root quizup-infrastructure
  quizup-identity quizup-theme quizup-profile quizup-game quizup-social
  quizup-matchmaking quizup-leaderboard quizup-gateway quizup-web
)

# Services à resynchroniser après recréation de l'infra (ordre : dépendances d'abord).
SERVICES=(
  quizup-identity quizup-theme quizup-profile quizup-game quizup-social
  quizup-matchmaking quizup-leaderboard quizup-gateway quizup-web
)

DBS=(
  quizup_identity quizup_theme quizup_game quizup_social
  quizup_matchmaking quizup_profile quizup_leaderboard
)

ASSUME_YES="false"
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  ASSUME_YES="true"
fi

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl introuvable" >&2; exit 1; }

if [[ "${ASSUME_YES}" != "true" ]]; then
  warn "Ce script EFFACE Postgres + Kafka de ${QUIZUP_NS} (toutes les données)."
  read -r -p "Confirmer ? (tapez 'reset') " answer
  [[ "${answer}" == "reset" ]] || { echo "annulé."; exit 1; }
fi

patch_app() {
  # $1 = application, $2 = patch JSON (merge)
  printf '%s' "$2" | kubectl -n "${ARGOCD_NS}" patch application "$1" \
    --type merge --patch-file /dev/stdin >/dev/null
}

autosync_off() { patch_app "$1" '{"spec":{"syncPolicy":null}}'; }
autosync_on()  { patch_app "$1" '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'; }
argocd_sync()  { patch_app "$1" '{"operation":{"initiatedBy":{"username":"reset.sh"},"sync":{"revision":"main","prune":true}}}'; }

wait_synced() {
  # $1 = application, $2 = timeout (s)
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

log "Contexte kubectl : $(kubectl config current-context 2>/dev/null || echo '?')"

log "1/8 Désactivation de l'auto-sync ArgoCD"
for app in "${APPS[@]}"; do
  if autosync_off "${app}"; then echo "  - ${app}"; else warn "ignoré (absent) : ${app}"; fi
done

log "2/8 Arrêt des services applicatifs"
kubectl -n "${QUIZUP_NS}" scale deploy --all --replicas=0
kubectl -n "${QUIZUP_NS}" scale statefulset postgres kafka --replicas=0

log "3/8 Suppression des StatefulSets + PVC (Postgres, Kafka)"
kubectl -n "${QUIZUP_NS}" delete statefulset postgres kafka --ignore-not-found
kubectl -n "${QUIZUP_NS}" delete pvc postgres-data-postgres-0 kafka-data-kafka-0 --ignore-not-found
kubectl -n "${QUIZUP_NS}" delete pvc -l app=postgres --ignore-not-found
kubectl -n "${QUIZUP_NS}" delete pvc -l app=kafka --ignore-not-found

log "4/8 Recréation de l'infra (Postgres vierge + 7 bases, Kafka vide)"
argocd_sync quizup-infrastructure
wait_synced quizup-infrastructure 300 || true

log "5/8 Attente de Postgres + Kafka"
kubectl -n "${QUIZUP_NS}" rollout status statefulset/postgres --timeout=300s
kubectl -n "${QUIZUP_NS}" exec statefulset/postgres -- pg_isready -U quizup
for db in "${DBS[@]}"; do
  for _ in $(seq 1 60); do
    if kubectl -n "${QUIZUP_NS}" exec statefulset/postgres -- \
        psql -U quizup -d "${db}" -c 'SELECT 1' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  echo "  - base prête : ${db}"
done
kubectl -n "${QUIZUP_NS}" rollout status statefulset/kafka --timeout=300s

log "6/8 Reconstruction des services (Flyway + seeders)"
for app in "${SERVICES[@]}"; do
  argocd_sync "${app}"
  wait_synced "${app}" 600 || true
done

log "7/8 Réactivation de l'auto-sync ArgoCD"
for app in "${APPS[@]}"; do
  autosync_on "${app}" && echo "  - ${app}"
done

log "8/8 Vérifications"
kubectl -n "${QUIZUP_NS}" get pods
echo
echo "  # bases disponibles :"
kubectl -n "${QUIZUP_NS}" exec statefulset/postgres -- psql -U quizup -lqt \
  | cut -d'|' -f1 | sed 's/ //g' | grep quizup_ || true
echo
echo "  # compte système (identity) :"
kubectl -n "${QUIZUP_NS}" exec statefulset/postgres -- \
  psql -U quizup -d quizup_identity -tAc "SELECT email FROM user_entry;" || true
echo
echo "  # sujets publiés (theme) :"
kubectl -n "${QUIZUP_NS}" exec statefulset/postgres -- \
  psql -U quizup -d quizup_theme -tAc \
  "SELECT count(*) FROM topic_entry WHERE status='PUBLISHED';" || true

log "Terminé : infra vierge + données reseedées."
