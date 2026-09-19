# AGENTS.md — quizup-gitops

> **DevOps / GitOps** : manifests Kubernetes + ArgoCD (app-of-apps) pour le cluster k3s
> des 2 Raspberry Pi 5. Hors périmètre de l'architecture hexagonale Java.

---

## 1. Rôle

Déployer QuizUp sur le cluster k3s via ArgoCD :

- **`argocd/root-app.yml`** : app-of-apps qui pilote `argocd/applications/`.
- **`infrastructure/`** : Postgres (multi-bases), **Kafka KRaft mono-broker**, config partagée
  des services, secret infra scellé.
- **`apps/<service>/`** : Deployment, Service, ConfigMap, Ingress, SealedSecret, Kustomization.
- **Addons via ArgoCD Applications Helm** : `cert-manager`, `cert-manager-webhook-ovh`,
  `sealed-secrets`.

Les machines (OS + k3s + bootstrap ArgoCD) sont provisionnées par **`quizup-infrastructure`**.

---

## 2. Conventions

- Domaine : `app.` / `api.` / `identity.` + `quizup.cnadjim.fr`.
- Images : `ghcr.io/quizup-organization/<service>`, **linux/arm64**, privées (`ghcr-pull`).
- TLS : `cert-manager.io/cluster-issuer: letsencrypt-prod` (OVH DNS-01).
- Secrets : **jamais en clair** → `scripts/seal-secrets.sh` (kubeseal).
- Toutes les apps sont dans le namespace `quizup-prod` ; addons dans `cert-manager` / `sealed-secrets`.
- `newTag` des images géré uniquement par `.github/workflows/update-image.yml`.

---

## 3. Services déployés

| Dossier | Image | Ingress |
|---|---|---|
| `apps/gateway` | `ghcr.io/quizup-organization/gateway` | `api.quizup.cnadjim.fr` |
| `apps/identity` | `ghcr.io/quizup-organization/identity` | `identity.quizup.cnadjim.fr` |
| `apps/theme` | `ghcr.io/quizup-organization/theme` | — |
| `apps/game` | `ghcr.io/quizup-organization/game` | — |
| `apps/social` | `ghcr.io/quizup-organization/social` | — |
| `apps/matchmaking` | `ghcr.io/quizup-organization/matchmaking` | — |
| `apps/profile` | `ghcr.io/quizup-organization/profile` | — |
| `apps/leaderboard` | `ghcr.io/quizup-organization/leaderboard` | — |
| `apps/quizup-web` | `ghcr.io/quizup-organization/quizup-web` | `app.quizup.cnadjim.fr` |

---

## 4. Pièges connus

- Le broker Axon est **Kafka** (extension `axon-kafka`), **pas RabbitMQ** : ne jamais réintroduire
  les variables `QUIZUP_RABBITMQ_*`.
- Les services déclarent le client OAuth2 `server-client` (`client_credentials`) requis par le
  `ResourceServerAutoConfiguration` du SDK, sinon le contexte Spring échoue au démarrage.
- `issuer` OIDC public (`identity.…`) mais `jwk-set-uri` **in-cluster** pour éviter le hairpin NAT.
