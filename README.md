# quizup-gitops

GitOps repository (ArgoCD app-of-apps) for the QuizUp Kubernetes cluster hosted on
**2× Raspberry Pi 5 (arm64)**. This repository replaces the former `quizup-deploy`.

> Host provisioning (OS + k3s) lives in **`quizup-infrastructure`** (Ansible).
> This repo only contains Kubernetes manifests applied by ArgoCD.

## Target

| URL | Component |
|---|---|
| `app.quizup.cnadjim.fr` | frontend (`quizup-web`, nginx) |
| `api.quizup.cnadjim.fr` | gateway (REST + WebSocket STOMP) |
| `identity.quizup.cnadjim.fr` | identity (OIDC issuer / JWT) |

- Cluster: **k3s** (1 server + 1 agent), ingress **Traefik** (bundled), storage **local-path**.
- Images: **`ghcr.io/quizup-organization/<service>`**, built for **linux/arm64** (private → `ghcr-pull` secret).
- TLS: **Let's Encrypt DNS-01** via **`cert-manager-webhook-ovh`** + the OVH API.
- Secrets: **sealed-secrets**.

## Layout

```
argocd/           # root app-of-apps + one Application per addon/app
namespaces/       # namespaces created before anything else
infrastructure/   # Postgres, Kafka (KRaft), shared service config, infra sealed-secret
apps/<service>/   # Deployment + Service + ConfigMap + Ingress + sealed-secret + kustomization
scripts/          # seal-secrets.sh (kubeseal helper)
.github/workflows # update-image (repository_dispatch) + validate
```

## Bootstrap

1. `cert-manager` and `sealed-secrets` are installed by their ArgoCD Applications.
2. Fetch the sealed-secrets public cert, then generate every `apps/*/sealed-secret.yml`
   (and `infrastructure/sealed-secret.yml`) with `scripts/seal-secrets.sh`.
3. Seal the OVH credentials into `cert-manager/ovh-credentials` (see below).
4. Create the CNAME/credentials for the OVH webhook issuer.
5. Point the root Application at this repo (done by `quizup-infrastructure`'s
   `argocd_bootstrap` role).

## OVH DNS-01 (Let's Encrypt)

`cert-manager-webhook-ovh` solves DNS-01 against the OVH API and creates the `ClusterIssuer`
`letsencrypt-prod` from its Helm values (`argocd/applications/cert-manager-webhook-ovh.yml`).

1. Create an OVH API key with `GET/PUT/POST/DELETE /domain/zone/*`
   (<https://api.ovh.com/createToken/>).
2. Seal the credentials in the `cert-manager` namespace:

   ```bash
   ./scripts/seal-secrets.sh ovh-credentials
   ```

3. Ensure `ovh-credentials` (SealedSecret) is synced **before** the webhook chart is installed
   (ArgoCD sync-wave `-1` on the Secret).

## Image updates (GitOps flow)

```
service repo push main → semantic-release → multi-arch (linux/arm64) image push to GHCR
  → repository_dispatch (type: deploy, service=<name>, version=<tag>) → quizup-gitops
  → .github/workflows/update-image.yml  → sed newTag in apps/<name>/kustomization.yml
  → ArgoCD auto-sync → rollout
```

`<name>` must match the `service-name` used by the release workflow (`identity`, `theme`, `game`,
`social`, `matchmaking`, `profile`, `leaderboard`, `gateway`, `quizup-web`).
