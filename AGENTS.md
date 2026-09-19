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
- **Addons via ArgoCD Applications** : `cert-manager`, `sealed-secrets`, `letsencrypt-issuer`
  (ClusterIssuer HTTP-01, solver Traefik) et `argocd-image-updater` (maj des tags d'images).

Les machines (OS + k3s + bootstrap ArgoCD) sont provisionnées par **`quizup-infrastructure`**.

---

## 2. Conventions

- Domaine : `app.` / `api.` / `identity.` + `quizup.cnadjim.fr`.
- Images : `ghcr.io/quizup-organization/<service>`, **linux/arm64**, privées (`ghcr-pull`).
- TLS : `cert-manager.io/cluster-issuer: letsencrypt-prod` (**HTTP-01** via Traefik).
- Secrets : **jamais en clair** → `scripts/seal-secrets.sh` (kubeseal).
- Toutes les apps sont dans le namespace `quizup-prod` ; addons dans `cert-manager` / `sealed-secrets`.
- Déploiement des images : **ArgoCD Image Updater** (git write-back du `newTag`), via le CR
  `argocd/image-updater/` et les annotations `argocd-image-updater.argoproj.io/*` sur les
  Applications. Plus de `repository_dispatch` / `update-image.yml`.

---

## 3. Services déployés

| Dossier            | Image                                     | Ingress                      |
|--------------------|-------------------------------------------|------------------------------|
| `apps/gateway`     | `ghcr.io/quizup-organization/gateway`     | `api.quizup.cnadjim.fr`      |
| `apps/identity`    | `ghcr.io/quizup-organization/identity`    | `identity.quizup.cnadjim.fr` |
| `apps/theme`       | `ghcr.io/quizup-organization/theme`       | —                            |
| `apps/game`        | `ghcr.io/quizup-organization/game`        | —                            |
| `apps/social`      | `ghcr.io/quizup-organization/social`      | —                            |
| `apps/matchmaking` | `ghcr.io/quizup-organization/matchmaking` | —                            |
| `apps/profile`     | `ghcr.io/quizup-organization/profile`     | —                            |
| `apps/leaderboard` | `ghcr.io/quizup-organization/leaderboard` | —                            |
| `apps/quizup-web`  | `ghcr.io/quizup-organization/quizup-web`  | `app.quizup.cnadjim.fr`      |

---

## 4. Pièges connus

- Le broker Axon est **Kafka** (extension `axon-kafka`), **pas RabbitMQ** : ne jamais réintroduire
  les variables `QUIZUP_RABBITMQ_*`.
- Les services déclarent le client OAuth2 `server-client` (`client_credentials`) requis par le
  `ResourceServerAutoConfiguration` du SDK, sinon le contexte Spring échoue au démarrage.
- `issuer` OIDC public (`identity.…`) mais `jwk-set-uri` **in-cluster** pour éviter le hairpin NAT.

---

## 5. Dépannage (retours d'expérience)

- **Port in-cluster** : les Services exposent **`port: 80`** (`targetPort: 8080`). Toutes les URLs
  internes doivent donc utiliser `http://<svc>.quizup-prod.svc.cluster.local` (**pas** `:8080`),
  sinon timeouts (`HTTP 000`) — concernait les routes gateway et `QUIZUP_AUTH_SERVER_URL/JWKS`.
- **`server-client` (OAuth2)** : un id de registration contenant un tiret **ne peut pas** être bindé
  depuis une variable d'environnement (`..._REGISTRATION_SERVER_CLIENT_...` → `server.client`). La
  config OAuth2 est donc passée via **`SPRING_APPLICATION_JSON`** (`infrastructure/service-common-config.yml`).
- **Axon/Kafka** : Axon utilise **`axon.kafka.bootstrap-servers`** (défaut `localhost:9092`), distinct
  de `spring.kafka.bootstrap-servers`. On injecte `AXON_KAFKA_BOOTSTRAP_SERVERS=kafka:9092`.
- **`QUIZUP_IDENTITY_JWK`** : requis en prod (JWK Set JSON `{"keys":[...]}`) ; le profil `prod`
  échoue au démarrage si absent (pas de génération éphémère).
- **Secrets DB** : un seul utilisateur Postgres `quizup` → **tous** les `QUIZUP_DB_PASSWORD` doivent
  valoir `POSTGRES_PASSWORD`. `seal-secrets.sh` prend `INFRA_POSTGRES_PASSWORD` par défaut.
- **Clients OIDC** : le seeder ne met pas à jour un client existant → après modification de
  `authentication.oauth2.clients`, supprimer la ligne puis redémarrer
  (`DELETE FROM oauth2_registered_client WHERE client_id='web';`).
- **Redirect URI** : le client `web` doit autoriser `https://app.quizup.cnadjim.fr/callback`.
- **Image Updater** : credentials registre + git (repo-creds) dans le namespace **`argocd`**
  (RBAC restreint à ce namespace) ; `write-back-method: git`, `git-branch: main`.
- **`leaderboard`** nécessite son `application-prod.yml` (datasource/kafka/jwt) comme les autres.
- **Frontend** : les variables Vite sont **inlinées au build** (voir `web/.github/workflows/release.yml`).
