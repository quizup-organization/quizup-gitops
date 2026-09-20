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
- **Observabilité** : `kube-prometheus-stack` (Prometheus/Grafana/Alertmanager/node-exporter/KSM)
  + `prometheus-blackbox-exporter` + ressources `monitoring/` (ServiceMonitors, Probes,
  PrometheusRules, exporters Postgres/Kafka, dashboards as code, AlertmanagerConfig Telegram).

Les machines (OS + k3s + bootstrap ArgoCD) sont provisionnées par **`quizup-infrastructure`**.

---

## 2. Conventions

- Domaine : `app.` / `api.` / `identity.` + `quizup.cnadjim.fr`.
- Images : `ghcr.io/quizup-organization/<service>`, **linux/arm64**, privées (`ghcr-pull`).
- TLS : `cert-manager.io/cluster-issuer: letsencrypt-prod` (**HTTP-01** via Traefik).
- Secrets : **jamais en clair** → `scripts/seal-secrets.sh` (kubeseal).
- Toutes les apps sont dans le namespace `quizup-prod` ; addons dans `cert-manager` / `sealed-secrets`.
- **Observabilité** : namespace `monitoring`. Grafana sur `grafana.quizup.cnadjim.fr` (TLS
  `letsencrypt-prod`, OIDC identity + admin break-glass). Prometheus/Alertmanager/Grafana/Loki ont
  des PVC `local-path`.
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

---

## 6. Observabilité

Stack auto-hébergée dans le namespace **`monitoring`**, déployée par ArgoCD en sync-waves :

| Application (wave)                 | Source                             | Rôle |
|------------------------------------|------------------------------------|------|
| `monitoring-secrets` (0)           | `monitoring/secrets/`              | SealedSecrets Grafana admin/OIDC + Telegram |
| `kube-prometheus-stack` (1)        | Helm `prometheus-community`        | Prometheus (15j, 8Gi), Alertmanager (1Gi), Grafana (2Gi), node-exporter, KSM |
| `prometheus-blackbox-exporter` (1) | Helm `prometheus-community`        | Sondes HTTP/TLS des endpoints publics |
| `monitoring` (2)                   | `monitoring/` (kustomize)          | ServiceMonitors, Probes, PrometheusRules, exporters Postgres/Kafka, dashboards, AlertmanagerConfig |

**Métriques applicatives** : les 8 services exposent `/actuator/prometheus` (Micrometer, endpoint
`permitAll`). `monitoring/service-monitors.yml` les scrape via le port de Service `http`
(`jobLabel: app`). Les tags `application`/`environment`/`version` viennent du SDK
(`ObservabilityAutoConfiguration`).

**Grafana** : `https://grafana.quizup.cnadjim.fr` — OIDC via `quizup-identity` (client `grafana`
**confidentiel** : `client_secret_basic` + PKCE ; `auth_url` public, `token_url`/`api_url`
**in-cluster**), rôle Admin si claim `roles` contient `ROLE_ADMIN`, sinon Viewer. Admin local
(break-glass) via le secret `grafana-admin`.
Le client secret OIDC est porté par le SealedSecret `quizup-identity-grafana` (namespace
`quizup-prod`), injecté dans le Deployment identity via `envFrom`.

**Dashboard as code** : ConfigMaps labellisées `grafana_dashboard: "1"` dans `monitoring/dashboards/`
(chargées par le sidecar Grafana, `searchNamespace: monitoring`).

**Alertes** : `monitoring/prometheus-rules.yml` (node/Pi, Kubernetes, apps, plateforme) →
`AlertmanagerConfig` Telegram (`monitoring/alertmanager-config.yml`). Le `chatID` est à renseigner
(inline, non secret) ; le token du bot vient du secret scellé `telegram-alertmanager`.

**Générer les secrets** : `SEALED_SECRETS_CERT=./sealed-secrets-cert.pem ./scripts/seal-secrets.sh monitoring`
(variables : `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_OIDC_CLIENT_SECRET`, `TELEGRAM_BOT_TOKEN`) et
`... ./scripts/seal-secrets.sh identity-grafana` (`GRAFANA_OIDC_CLIENT_SECRET`).
