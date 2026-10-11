# demo-gitops

The desired state of every environment: **which version** of each service runs where, and **with which
config**. ArgoCD watches this repo and makes the clusters match it.

Services: [`demo-catalog-service`](https://github.com/vehkiya/demo-catalog-service),
[`demo-orders-service`](https://github.com/vehkiya/demo-orders-service).

## Layout

```
envs/                              ← where almost every change happens
├── dev/
│   ├── env.yaml                   cluster, namespace, autoSync (read by the ApplicationSet)
│   ├── application.yaml           Spring overrides for ALL services in dev
│   ├── catalog/
│   │   ├── kustomization.yaml     image (set by CI), replicas, ConfigMap generator
│   │   └── application.yaml       catalog overrides in dev
│   └── orders/
│       ├── kustomization.yaml
│       ├── application.yaml
│       └── external-secret.yaml   payment API key from OpenBao
├── stage/                         same shape
└── prod/                          same shape + pdb.yaml, 2 replicas

apps/<service>/base/               how a service runs in any env (Deployment, Service)
components/spring-boot/            golden path for every service: probes, ports, security, JVM flags, config wiring
argocd/                            AppProject + ApplicationSet (bootstrap)
scripts/                           render, compare, promote, check
.github/workflows/                 java-service (reusable CI), promote, pr-checks
```

## How config works

Each service has **one** `application.yaml` inside its jar with defaults for every property. This repo only holds
what differs per environment, as plain Spring Boot YAML:

| Precedence | Source | Example |
|---|---|---|
| 1 (lowest) | jar `application.yaml` | `orders.max-items-per-order: 10` |
| 2 | `envs/<env>/application.yaml` | `logging.level.org.springframework: WARN` in prod |
| 3 | `envs/<env>/<service>/application.yaml` | `orders.payment.mode: live` in prod |
| 4 (highest) | env vars: platform settings + secrets | `SERVER_PORT`, `ORDERS_PAYMENT_APIKEY` |

Layers 2 and 3 become one ConfigMap mounted at `/config`. Its name carries a content hash, so **any override change
rolls the pods** automatically, with no image build. Services reject unknown or invalid properties at startup, so a bad
override never takes traffic: the old pods keep serving and ArgoCD shows the app as Degraded.

## I want to…

| Task | Do this |
|---|---|
| Change a value in one env | Edit `envs/<env>/<service>/application.yaml`, open a PR |
| Change a value for all services in one env | Edit `envs/<env>/application.yaml` |
| Ship new code to dev | Merge to `main` in the service repo. CI commits the new image here |
| Promote to stage / prod | Actions → **promote** → service + target. Opens a PR (stage auto-merges, prod needs review) |
| Roll back | Revert the promotion (or config) commit. ArgoCD rolls back image and config together |
| Scale | `replicas:` in `envs/<env>/<service>/kustomization.yaml` |
| Add a secret | Store it in OpenBao under `secret/demo/<env>/<service>`, map it in `external-secret.yaml` |
| Add a service | `apps/<service>/base/` + `envs/<env>/<service>/` for each env. The ApplicationSet picks it up |
| Add an environment | `envs/<env>/` with an `env.yaml` |

## Scripts

Need `kustomize` (or `kubectl`) and [mikefarah yq v4](https://github.com/mikefarah/yq). Both are preinstalled on
GitHub runners.

| Command | Answers |
|---|---|
| `scripts/versions.sh` | Which version runs where? (`=` means same digest as the previous env) |
| `scripts/effective-config.sh orders prod` | What config does orders get in prod, and from which layer? |
| `scripts/diff-envs.sh orders stage prod` | Why does stage behave differently from prod? (image, overrides, effective config, manifests) |
| `scripts/render.sh orders prod` | What exactly will ArgoCD apply? |
| `scripts/render-all.sh out/` + `scripts/policy.sh out/` | Does everything render and pass the guardrails? |

`effective-config.sh` reads jar defaults from the service repo at the commit deployed in that env, falling back to a
sibling checkout (`../demo-orders-service`).

```
$ scripts/effective-config.sh orders prod --app-only
orders.catalog.base-url          = http://catalog:8080                        # jar (kubernetes)
orders.catalog.max-retries       = 2                                          # jar
orders.catalog.timeout           = 1s                                         # envs/prod/orders/application.yaml
orders.express-shipping.enabled  = false                                      # jar
orders.max-items-per-order       = 10                                         # jar
orders.payment.apikey            = <secret demo/prod/orders#payment-api-key>  # secret
orders.payment.mode              = live                                       # envs/prod/orders/application.yaml
orders.payment.provider-url      = https://api.payments.example               # envs/prod/orders/application.yaml
```

## Delivery flow

| Env | Arrives via | Gate |
|---|---|---|
| dev | Service CI commits `envs/dev/<service>` on every merge to `main` | Service tests |
| stage | **promote** workflow PR (dev → stage) | `pr-checks`, then auto-merge |
| prod | **promote** workflow PR (stage → prod) | `pr-checks` + CODEOWNERS review |

Every PR gets a comment with the **rendered manifest diff**: exactly what ArgoCD will change.

Images start as the placeholder tag `bootstrap` (not pullable) until the first CI run in each service repo.

## Setup

**Repository settings**
- Secret `GITOPS_TOKEN`: fine-grained PAT with *Contents* and *Pull requests* read/write on this repo. Also add it
  to both service repos.
- Ruleset on `main`: require a PR, require the `checks` status (from `pr-checks`), require code-owner review; allow
  the repository admin to bypass (service CI pushes dev bumps directly).
- Settings → General → *Allow auto-merge*.
- After the first CI run in each service repo: make the GHCR packages public.

**Cluster (home lab)**
1. ArgoCD: add `--load-restrictor LoadRestrictionsNone` to `kustomize.buildOptions` in `argocd-cm`. It's needed
   because the per-service overlays read the env-wide `../application.yaml`.
2. OpenBao: let the ESO role read `secret/data/demo/*`, then seed the keys:
   ```sh
   bao kv put secret/demo/dev/orders   payment-api-key=dev-key-1111
   bao kv put secret/demo/stage/orders payment-api-key=stage-key-2222
   bao kv put secret/demo/prod/orders  payment-api-key=prod-key-3333
   ```
3. Bootstrap: an Application in the `default` project with source `path: argocd` of this repo, destination
   namespace `argocd`. It creates the `demo` AppProject and the ApplicationSet, which creates the six apps
   (`<service>-<env>`).

**Look at it** (no ingress):
```sh
kubectl -n demo-stage port-forward svc/orders 8080:8080
kubectl -n demo-stage port-forward deploy/orders 9000:9000   # /actuator/info, /actuator/configsources
```

**On EKS:** set `cluster` and `namespace` in each `env.yaml`, adjust the AppProject destinations, and point the
ExternalSecrets at the AWS Secrets Manager store. Nothing else changes.
