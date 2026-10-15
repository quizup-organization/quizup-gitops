#!/usr/bin/env bash
#
# Reset « base saine » de la prod QuizUp : purge Postgres + Kafka (volumes neufs),
# reconstruit l'infra vierge (8 bases + Kafka vide) puis resynchronise les applications
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
#   ./scripts/reset.sh --yes --media   # purge en plus le bucket média (MinIO)
#
# --media : vide le bucket `quizup-media` (objets + bucket), le recrée (lecture publique,
# écriture BFF) puis **republie les images du seed** depuis le workspace. À lancer avec le
# lot qui change les visuels du seed.
#
set -euo pipefail

QUIZUP_NS="${QUIZUP_NS:-quizup-prod}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

# app-of-apps + infra + services : on coupe leur auto-sync pendant la purge.
APPS=(
  quizup-root quizup-infrastructure
  quizup-identity quizup-theme quizup-profile quizup-game quizup-social
  quizup-matchmaking quizup-leaderboard quizup-notification quizup-web
)

# Services à resynchroniser après recréation de l'infra (ordre : dépendances d'abord).
SERVICES=(
  quizup-identity quizup-theme quizup-profile quizup-game quizup-social
  quizup-matchmaking quizup-leaderboard quizup-notification quizup-web
)

DBS=(
  quizup_identity quizup_theme quizup_game quizup_social
  quizup_matchmaking quizup_profile quizup_leaderboard quizup_notification
)

ASSUME_YES="false"
MEDIA="false"
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES="true" ;;
    --media)  MEDIA="true" ;;
    *) echo "option inconnue : ${arg}" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl introuvable" >&2; exit 1; }

if [[ "${ASSUME_YES}" != "true" ]]; then
  warn "Ce script EFFACE Postgres + Kafka de ${QUIZUP_NS} (toutes les données)."
  if [[ "${MEDIA}" == "true" ]]; then
    warn "Option --media : EFFACE aussi tous les objets média (MinIO) puis republie le seed."
  fi
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

# Bucket média (MinIO) : purge + republication du seed (option --media).
MEDIA_BUCKET="${MEDIA_BUCKET:-quizup-media}"

purge_media() {
  # Réutilise le client MinIO du hook `minio-init` (image déjà tirée, secrets scellés du
  # cluster) : supprime le bucket puis rejoue l'init idempotent (bucket + lecture publique +
  # utilisateur d'écriture du BFF).
  kubectl -n "${QUIZUP_NS}" delete job media-purge --ignore-not-found >/dev/null
  kubectl -n "${QUIZUP_NS}" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: media-purge
  namespace: ${QUIZUP_NS}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: media-purge
          image: docker.io/bitnamilegacy/minio-client
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -eu
              MC="\${MC:-mc}"
              command -v "\$MC" >/dev/null 2>&1 || MC=/opt/bitnami/mc/bin/mc
              i=0
              until "\$MC" alias set local http://minio "\$MINIO_ROOT_USER" "\$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
                i=\$((i + 1))
                if [ "\$i" -ge 60 ]; then echo "minio indisponible" >&2; exit 1; fi
                sleep 5
              done
              "\$MC" rb --force "local/${MEDIA_BUCKET}" || true
              bash /config/setup.sh
          envFrom:
            - secretRef:
                name: quizup-minio-secret
            - secretRef:
                name: quizup-bff-media
          volumeMounts:
            - name: config
              mountPath: /config
      volumes:
        - name: config
          configMap:
            name: quizup-minio-init
EOF
  if ! kubectl -n "${QUIZUP_NS}" wait --for=condition=complete job/media-purge \
      --timeout=300s >/dev/null 2>&1; then
    kubectl -n "${QUIZUP_NS}" logs job/media-purge >&2 || true
    warn "purge média en échec (job media-purge conservé pour inspection)"
    return 1
  fi
  kubectl -n "${QUIZUP_NS}" logs job/media-purge
  kubectl -n "${QUIZUP_NS}" delete job media-purge >/dev/null
}

publish_seed_images() {
  # Le bucket vient d'être vidé : on republie les images mirorées du seed depuis le workspace
  # (`scripts/seed-images.py publish`, boto3 + fichier de `product/wikipedia/`).
  local default_script script
  default_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/seed-images.py"
  script="${SEED_IMAGES_SCRIPT:-${default_script}}"
  if [[ ! -f "${script}" ]]; then
    warn "images du seed NON republiées (script introuvable : ${script})"
    echo "  -> depuis le workspace : make seed-images ACTION=publish"
    return 0
  fi
  local access secret
  access="$(kubectl -n "${QUIZUP_NS}" get secret quizup-bff-media \
    -o jsonpath='{.data.QUIZUP_MEDIA_ACCESS_KEY}' | base64 -d)"
  secret="$(kubectl -n "${QUIZUP_NS}" get secret quizup-bff-media \
    -o jsonpath='{.data.QUIZUP_MEDIA_SECRET_KEY}' | base64 -d)"
  if ! MINIO_ENDPOINT="${MEDIA_PUBLISH_ENDPOINT:-https://media.quizup.cnadjim.fr}" \
      MINIO_BUCKET="${MEDIA_BUCKET}" \
      MINIO_ACCESS_KEY="${access}" MINIO_SECRET_KEY="${secret}" \
      python3 "${script}" publish; then
    warn "republication des images du seed en échec"
    echo "  -> relancer depuis le workspace :"
    echo "     MINIO_ENDPOINT=https://media.quizup.cnadjim.fr MINIO_BUCKET=${MEDIA_BUCKET} \\"
    echo "       MINIO_ACCESS_KEY=… MINIO_SECRET_KEY=… make seed-images ACTION=publish"
    return 1
  fi
}

log "Contexte kubectl : $(kubectl config current-context 2>/dev/null || echo '?')"log "1/8 Désactivation de l'auto-sync ArgoCD"
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

if [[ "${MEDIA}" == "true" ]]; then
  log "3bis/8 Purge du bucket média (MinIO) + recréation (lecture publique, écriture BFF)"
  purge_media || true
fi

log "4/8 Recréation de l'infra (Postgres vierge + 8 bases, Kafka vide)"
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

log "6bis/8 Restauration des Deployments pilotés par HPA (scaling désactivé à 0)"
# `kubectl scale --all --replicas=0` laisse un Deployment HPA à 0 : le controller refuse alors de
# recalculer (« scaling is disabled since the replica count of the target is zero »). On remonte
# chaque cible à son minReplicas ; le HPA reprend la main ensuite. Les manifestes ne fixent pas
# `replicas` pour ces Deployments, ArgoCD ne les écrase donc pas.
for hpa in $(kubectl -n "${QUIZUP_NS}" get hpa -o name 2>/dev/null); do
  target="$(kubectl -n "${QUIZUP_NS}" get "${hpa}" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"
  min="$(kubectl -n "${QUIZUP_NS}" get "${hpa}" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
  if [[ -n "${target}" && -n "${min}" ]]; then
    kubectl -n "${QUIZUP_NS}" scale "deployment/${target}" --replicas="${min}" >/dev/null
    echo "  - ${target} -> ${min} (HPA)"
  fi
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

if [[ "${MEDIA}" == "true" ]]; then
  log "8bis/8 Republication des images du seed (bucket média vidé)"
  publish_seed_images || true
fi
