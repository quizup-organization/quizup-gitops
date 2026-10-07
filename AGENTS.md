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
- **Nommage (une seule convention)** : `spring.application.name` = nom du Deployment = nom du
  Service = valeur du label `app` = **`quizup-<service>`** (ex. `quizup-theme`). Les Services
  applicatifs portent aussi `app.kubernetes.io/part-of: quizup` (monitoring) et, pour les services
  Axon, `app.kubernetes.io/component: axon` (découverte). L'infra `postgres`/`kafka` fait exception
  (contrainte PVC des StatefulSets).

---

## 3. Services déployés

| Dossier            | Nom k8s (`app`)     | Image                                     | Ingress                      |
|--------------------|---------------------|-------------------------------------------|------------------------------|
| `apps/gateway`     | `quizup-gateway`    | `ghcr.io/quizup-organization/gateway`     | `api.quizup.cnadjim.fr`      |
| `apps/identity`    | `quizup-identity`   | `ghcr.io/quizup-organization/identity`    | `identity.quizup.cnadjim.fr` |
| `apps/theme`       | `quizup-theme`      | `ghcr.io/quizup-organization/theme`       | —                            |
| `apps/game`        | `quizup-game`       | `ghcr.io/quizup-organization/game`        | —                            |
| `apps/social`      | `quizup-social`     | `ghcr.io/quizup-organization/social`      | —                            |
| `apps/matchmaking` | `quizup-matchmaking`| `ghcr.io/quizup-organization/matchmaking` | —                            |
| `apps/profile`     | `quizup-profile`    | `ghcr.io/quizup-organization/profile`     | —                            |
| `apps/leaderboard` | `quizup-leaderboard`| `ghcr.io/quizup-organization/leaderboard` | —                            |
| `apps/notification`| `quizup-notification`| `ghcr.io/quizup-organization/notification` | —                          |
| `apps/quizup-web`  | `quizup-web`        | `ghcr.io/quizup-organization/quizup-web`  | `app.quizup.cnadjim.fr`      |

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
  internes doivent donc utiliser `http://quizup-<svc>.quizup-prod.svc.cluster.local` (**pas** `:8080`),
  sinon timeouts (`HTTP 000`) — concernait les routes gateway et `QUIZUP_AUTH_SERVER_URL/JWKS`.
- **Découverte des pairs (bus Axon)** : en prod, `SPRING_CLOUD_KUBERNETES_ENABLED=true` et
  `SPRING_CLOUD_KUBERNETES_DISCOVERY_ENABLED=true` (SDK, dépendance `spring-cloud-starter-kubernetes-client`).
  Le RBAC `infrastructure/rbac.yml` (Role/RoleBinding, SA `default`) est **requis** sinon
  `403 Forbidden` sur `list services/endpoints`. Le SDK filtre sur `app.kubernetes.io/component=axon`
  (les non-Axon comme `quizup-gateway`/`quizup-web` ne sont pas découverts). En local, découverte
  désactivée : les `application-local.yml` déclarent `spring.cloud.discovery.client.simple.instances`.
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
- **Web Push (BFF)** : la paire **VAPID** doit rester stable à vie (une rotation invalide tous les
  abonnements navigateur → purger `push_subscription` et faire re-souscrire). La clé publique +
  le subject vont dans le ConfigMap `quizup-bff-config`, la privée dans le SealedSecret dédié
  `quizup-bff-push` (`QUIZUP_PUSH_VAPID_PRIVATE_KEY`, requis par `seal-secrets.sh bff-push`).
  Sans clés, le push est désactivé silencieusement (le STOMP reste la voie nominale).
  Génération : `npx web-push generate-vapid-keys`, puis
  `QUIZUP_PUSH_VAPID_PRIVATE_KEY=… ./scripts/seal-secrets.sh bff-push`.
- **Emails OTP** : les codes de connexion sont envoyés via **Resend**. `QUIZUP_MAIL_API_KEY` est
  portée par le secret `quizup-identity-secret` (resceller avec `QUIZUP_MAIL_API_KEY=… ./scripts/seal-secrets.sh identity`).
  `QUIZUP_MAIL_FROM` / `QUIZUP_MAIL_BASE_URL` sont dans le ConfigMap identity.
- **Rôles admin** : `QUIZUP_ADMIN_EMAILS` (ConfigMap identity) est une liste d'emails séparés par
  des virgules obtenant `ROLE_ADMIN` (mappé Admin côté Grafana). Le **compte système unique**
  (`quizup.contacts@gmail.com`) est aussi admin et sert de bot.
- **Seeding** : `QUIZUP_SEED_DATA_ENABLED=true` pour `identity` (compte système), `profile`
  (profil système) et `theme` (25 sujets de départ, seed YAML auto-réparateur). Seeders idempotents.
  Le seeder `theme` retente les échecs transitoires (instance Axon périmée pendant un rollout :
  jusqu'à 4 tentatives, backoff 2s×n) et expose `quizup_theme_seed_topics_total{outcome="failed"}`
  → alerte `QuizupThemeSeedFailures` ; un thème laissé `DRAFT` se répare au prochain redémarrage
  du pod (`kubectl delete pod` — pas de `rollout restart`, ArgoCD self-heal annulerait l'annotation).
- **Resend** : l'envoi OTP échoue en `403 validation_error` tant que le domaine de `QUIZUP_MAIL_FROM`
  (`quizup.cnadjim.fr`) n'est pas **vérifié dans Resend** (ajouter les enregistrements SPF/DKIM DNS).
  Le endpoint `/api/auth/request-code` renvoie quand même `202` (anti-énumération) : vérifier les
  logs identity (`Failed to send login code`).
- **Processeurs Axon (poison pill)** : un événement qui échoue en boucle (ex. recréation d'agrégat
  après relecture) bloque **silencieusement** tout l'ingest d'un service — le read model ne bouge
  plus alors que le service est `Ready`. Garde-fous : règles `quizup.axon`
  (`QuizupAxonEventProcessorErrors`, `QuizupAxonEventProcessingFailures`) dans
  `monitoring/prometheus-rules.yml`, dashboard `axon-activity`. En cas d'alerte : vérifier
  `EventProcessor[<group>]` dans les logs du service et le token (`token_entry`).

---

## 6. Observabilité

Stack auto-hébergée dans le namespace **`monitoring`**, déployée par ArgoCD en sync-waves :

| Application (wave)                 | Source                             | Rôle |
|------------------------------------|------------------------------------|------|
| `monitoring-secrets` (0)           | `monitoring/secrets/`              | SealedSecrets Grafana admin/OIDC + Telegram |
| `kube-prometheus-stack` (1)        | Helm `prometheus-community`        | Prometheus (15j, 8Gi), Alertmanager (1Gi), Grafana (2Gi), node-exporter, KSM |
| `prometheus-blackbox-exporter` (1) | Helm `prometheus-community`        | Sondes HTTP/TLS des endpoints publics |
| `loki` (1)                         | Helm `grafana` (`loki` 7.3.0)      | Stockage des logs (SingleBinary, filesystem, 14j, PVC 10Gi) |
| `tempo` (1)                        | Helm `grafana` (`tempo` 1.24.3)    | Stockage des traces (OTLP, 7j, PVC 5Gi) |
| `otel-collector` (1)               | Helm `open-telemetry`              | Collecteur OTLP → Tempo |
| `alloy` (2)                        | Helm `grafana` (`alloy` 1.12.1)    | DaemonSet de collecte des logs (`/var/log/pods`) → Loki |
| `monitoring` (2)                   | `monitoring/` (kustomize)          | ServiceMonitors, Probes, PrometheusRules, exporters Postgres/Kafka, dashboards, datasources, AlertmanagerConfig |

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

**Logs / traces** : les services émettent des **logs structurés JSON ECS** (SDK) collectés par
**Alloy** (DaemonSet) → **Loki** ; les **traces** (Micrometer/Otel + Axon) partent en OTLP vers
l'**otel-collector** → **Tempo**, activées par `MICROSERVICE_OBSERVABILITY_TRACING_ENABLED=true`.
Les datasources Loki/Tempo et leurs corrélations sont dans `monitoring/grafana-datasources.yml`.

**Dashboard as code** : ConfigMaps labellisées `grafana_dashboard: "1"` dans `monitoring/dashboards/`
(chargées par le sidecar Grafana, `searchNamespace: monitoring`).

**Alertes** : `monitoring/prometheus-rules.yml` (node/Pi, Kubernetes, apps, plateforme) →
`AlertmanagerConfig` Telegram (`monitoring/alertmanager-config.yml`). Le `chatID` est à renseigner
(inline, non secret) ; le token du bot vient du secret scellé `telegram-alertmanager`.

**Générer les secrets** : `SEALED_SECRETS_CERT=./sealed-secrets-cert.pem ./scripts/seal-secrets.sh monitoring`
(variables : `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_OIDC_CLIENT_SECRET`, `TELEGRAM_BOT_TOKEN`) et
`... ./scripts/seal-secrets.sh identity-grafana` (`GRAFANA_OIDC_CLIENT_SECRET`).

---

## 7. Reset « base saine » (production)

Le reset complet efface **Postgres + Kafka** (les anciens événements Kafka seraient sinon rejoués
dans les projections neuves), puis reconstruit l'infra vierge (7 bases + Kafka vide) et
resynchronise les applications (Flyway + seeders idempotents). Il est **scripté** (kubectl seul,
sans CLI `argocd`) :

```bash
cd devops/quizup-gitops
./scripts/reset.sh            # demande confirmation
./scripts/reset.sh --yes      # non interactif (release)
```

**Exécution prod** : le kubeconfig k3s est sur `pi-node1` (SSH `pi@176.144.234.135 -p 2222`).
Le script ne dépend d'aucun fichier local (kubectl uniquement) et peut être exécuté à distance :

```bash
ssh -p 2222 pi@176.144.234.135 'bash -s -- --yes' < scripts/reset.sh
```

Déroulé : désactivation de l'auto-sync ArgoCD → arrêt des services → suppression des
StatefulSets/PVC `postgres`/`kafka` → resync infra (Postgres vierge + init des 7 bases, Kafka
vide) → attente Postgres/Kafka → resync des services → réactivation de l'auto-sync → vérifications.

**À lancer avec le rollout du lot** qui change un schéma `V1` (les volumes neufs rejouent les
migrations) : ex. le lot seed YAML + `topic_entry.image_url` (`theme` ≥ 2.2.0). Le reset doit
coïncider avec le déploiement du nouveau tag, sinon Flyway détecte un checksum différent et le pod
part en `CrashLoopBackOff`. Si le tag est déjà dans les manifests (ArgoCD Image Updater), couper
l'auto-sync des apps `quizup-*` avant le rollout, puis lancer le reset (il la réactive en fin de
script) — ou lancer le reset immédiatement après le rollout.

**Vérifications** : `user_entry` contient le compte système (sans mot de passe), `profile` a son
profil, `theme` a 20 sujets publiés, et les compteurs (`topic_entry.followers_counter`) sont nuls
au départ. Les sessions en base étant purgées, tout le monde doit se reconnecter.

