#!/usr/bin/env bash
#
# Génère les SealedSecrets du repo quizup-gitops.
#
# Prérequis :
#   export SEALED_SECRETS_CERT=./sealed-secrets-cert.pem   # kubeseal --fetch-cert > ...
#   kubectl + kubeseal disponibles
#
# Usage :
#   ./scripts/seal-secrets.sh all
#   ./scripts/seal-secrets.sh identity
#   ./scripts/seal-secrets.sh infra
#   ./scripts/seal-secrets.sh ghcr-pull
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${SEALED_SECRETS_CERT:?SEALED_SECRETS_CERT doit pointer vers le certificat public sealed-secrets}"

seal_generic() {
  local ns="$1" name="$2" out="$3"
  shift 3
  kubectl create secret generic "${name}" --namespace "${ns}" "$@" \
    --dry-run=client -o json \
    | kubeseal --cert "${SEALED_SECRETS_CERT}" --format=yaml \
    > "${ROOT_DIR}/${out}"
  echo "sealed: ${out}"
}

seal_docker() {
  local ns="$1" name="$2" out="$3"
  shift 3
  kubectl create secret docker-registry "${name}" --namespace "${ns}" "$@" \
    --dry-run=client -o json \
    | kubeseal --cert "${SEALED_SECRETS_CERT}" --format=yaml \
    > "${ROOT_DIR}/${out}"
  echo "sealed: ${out}"
}

# Secret client OAuth2 `server-client` (client_credentials) partagé par les services.
server_client_secret() {
  printf -- "--from-literal=SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_SERVER_CLIENT_CLIENT_SECRET=%s" \
    "${IDENTITY_SERVER_CLIENT_SECRET:?IDENTITY_SERVER_CLIENT_SECRET manquant}"
}

seal_service() {
  local svc="$1"
  local upper
  upper="$(echo "${svc}" | tr '[:lower:]-' '[:upper:]_')"
  local var_db_pass="${upper}_DB_PASSWORD"
  local db_pass="${!var_db_pass:-}"

  seal_generic quizup-prod "quizup-${svc}-secret" "apps/${svc}/sealed-secret.yml" \
    --from-literal=QUIZUP_DB_PASSWORD="${db_pass:?${var_db_pass} manquant}" \
    "$(server_client_secret)"
}

seal_gateway() {
  # Le gateway n'a pas de datasource : seul le client OAuth2 `server-client` est requis.
  seal_generic quizup-prod quizup-gateway-secret apps/gateway/sealed-secret.yml \
    "$(server_client_secret)"
}

seal_identity() {
  seal_generic quizup-prod quizup-identity-secret apps/identity/sealed-secret.yml \
    --from-literal=QUIZUP_DB_PASSWORD="${IDENTITY_DB_PASSWORD:?IDENTITY_DB_PASSWORD manquant}" \
    --from-literal=QUIZUP_IDENTITY_SERVER_CLIENT_SECRET="${IDENTITY_SERVER_CLIENT_SECRET:?IDENTITY_SERVER_CLIENT_SECRET manquant}" \
    --from-literal=QUIZUP_IDENTITY_ADMIN_CLIENT_SECRET="${IDENTITY_ADMIN_CLIENT_SECRET:?IDENTITY_ADMIN_CLIENT_SECRET manquant}" \
    --from-literal=QUIZUP_IDENTITY_JWK="${IDENTITY_JWK:-}"
}

seal_infra() {
  seal_generic quizup-prod quizup-infra-secret infrastructure/sealed-secret.yml \
    --from-literal=POSTGRES_PASSWORD="${INFRA_POSTGRES_PASSWORD:?INFRA_POSTGRES_PASSWORD manquant}"
}

seal_ghcr() {
  seal_docker quizup-prod ghcr-pull infrastructure/registry-secret.yml \
    --docker-server=ghcr.io \
    --docker-username="${GHCR_USERNAME:?GHCR_USERNAME manquant}" \
    --docker-password="${GHCR_TOKEN:?GHCR_TOKEN manquant}" \
    --docker-email="${GHCR_EMAIL:-unused@quizup.local}"
}

seal_all() {
  seal_infra
  seal_ghcr
  seal_identity
  for svc in theme game social matchmaking profile leaderboard; do
    seal_service "${svc}"
  done
  seal_gateway
}

case "${1:-all}" in
  all) seal_all ;;
  identity) seal_identity ;;
  gateway) seal_gateway ;;
  infra) seal_infra ;;
  ghcr-pull) seal_ghcr ;;
  theme|game|social|matchmaking|profile|leaderboard) seal_service "$1" ;;
  *)
    echo "usage: $0 [all|infra|ghcr-pull|identity|theme|game|social|matchmaking|profile|leaderboard|gateway]" >&2
    exit 1
    ;;
esac
