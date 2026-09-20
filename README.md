# quizup-gitops

GitOps repository (ArgoCD app-of-apps) for the QuizUp Kubernetes cluster hosted on Raspberry Pi 5 (arm64)**.

> Host provisioning (OS + k3s) lives in **`quizup-infrastructure`** (Ansible).
> This repo only contains Kubernetes manifests applied by ArgoCD.

## Target

| URL                          | Component                        |
|------------------------------|----------------------------------|
| `app.quizup.cnadjim.fr`      | frontend (`quizup-web`, nginx)   |
| `api.quizup.cnadjim.fr`      | gateway (REST + WebSocket STOMP) |
| `identity.quizup.cnadjim.fr` | identity (OIDC issuer / JWT)     |
| `grafana.quizup.cnadjim.fr`  | observabilité (Grafana / OIDC)   |

- Cluster: **k3s** (1 server + 1 agent), ingress **Traefik** (bundled), storage **local-path**.
- Images: **`ghcr.io/quizup-organization/<service>`**, built for **linux/arm64** (private → `ghcr-pull` secret).
- TLS: **Let's Encrypt HTTP-01** via cert-manager (solver ingress **Traefik**).
- Secrets: **sealed-secrets**.

## Layout

```
argocd/           # root app-of-apps + one Application per addon/app
namespaces/       # namespaces created before anything else
cert-manager/     # ClusterIssuer letsencrypt-prod (HTTP-01, solver Traefik)
infrastructure/   # Postgres, Kafka (KRaft), shared service config, infra sealed-secret
monitoring/       # Prometheus/Grafana/Alertmanager, ServiceMonitors, Probes, rules, dashboards
apps/<service>/   # Deployment + Service + ConfigMap + Ingress + sealed-secret + kustomization
scripts/          # seal-secrets.sh (kubeseal helper)
.github/workflows # validate (kustomize + yamllint)
```

## Bootstrap

1. `cert-manager`, `sealed-secrets` and the `letsencrypt-issuer` are installed by their
   ArgoCD Applications (issuer at sync-wave `1`, after cert-manager).
2. Fetch the sealed-secrets public cert, then generate every `apps/*/sealed-secret.yml`
   (and `infrastructure/sealed-secret.yml`) with `scripts/seal-secrets.sh`.
3. Point the root Application at this repo (done by `quizup-infrastructure`'s
   `argocd_bootstrap` role).

## TLS (Let's Encrypt HTTP-01)

The `letsencrypt-issuer` Application applies a cluster-scoped `ClusterIssuer`
`letsencrypt-prod` (`cert-manager/cluster-issuer.yml`) whose **HTTP-01** solver uses the
**Traefik** ingress class. The public Ingress (`api.` / `identity.` / `app.`) reference it via
`cert-manager.io/cluster-issuer: letsencrypt-prod`; cert-manager temporarily exposes the
challenge through Traefik. No OVH API key and no DNS-01 webhook are required.

Prerequisites: the DNS A records already point to the public IP (DDNS DynHost) and **port 80**
is reachable from the Internet.

## Observabilité (monitoring)

Stack auto-hébergée dans le namespace `monitoring` :

- **kube-prometheus-stack** (Helm) : Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics.
- **prometheus-blackbox-exporter** : sondes HTTP/TLS des endpoints publics.
- **`monitoring/`** : ServiceMonitors (`/actuator/prometheus`), Probes, PrometheusRules, exporters
  Postgres/Kafka, dashboards Grafana as code, routage Telegram.

Grafana : `https://grafana.quizup.cnadjim.fr` — OIDC `quizup-identity` (client `grafana`) + admin
local scellé. Secrets générés avec `./scripts/seal-secrets.sh monitoring`.

## Image updates (GitOps flow)

```
service repo push main → semantic-release → image linux/arm64 → GHCR
  → ArgoCD Image Updater (git write-back du newTag dans apps/<name>/kustomization.yml)
  → ArgoCD auto-sync → rollout
```

Le déploiement est assuré par **ArgoCD Image Updater** (CR `argocd/image-updater/` + annotations
`argocd-image-updater.argoproj.io/*` sur les Applications) : plus de `repository_dispatch` ni de
workflow `update-image.yml` côté service.

`<name>` must match the `service-name` used by the release workflow (`identity`, `theme`, `game`,
`social`, `matchmaking`, `profile`, `leaderboard`, `gateway`, `quizup-web`).
