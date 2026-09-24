# CLAUDE.md

This file provides guidance to Claude Code when working with this GitOps repository.

## Project Overview

This is a **GitOps repository** for managing Kubernetes/OpenShift infrastructure and applications using **ArgoCD**. It deploys EAP (Enterprise Application Platform) workloads through an app-of-apps pattern, using two ArgoCD Applications (OpenBao deployed first, then infrastructure) and Kustomize for application workloads.

## Repository Structure

```
app-mod-gitops/
├── gitops/                              # ArgoCD Application definitions
│   ├── install-gitops.yaml              # Bootstrap: GitOps operator + RBAC
│   ├── infra/                           # Infrastructure applications
│   │   ├── application-openbao.yaml     # Multi-source: OpenBao Helm repo + plain manifests
│   │   └── application-infra.yaml       # Single-source: infra Helm chart from Git
│   └── applications/                    # App-of-apps deployments (per EAP app)
│       └── <app-name>/
│           ├── application-of-apps.yaml
│           └── apps/
│               ├── deploy/              # Deploy-phase ArgoCD Application
│               └── s2i/                 # S2I build-phase ArgoCD Application
├── manifests/                           # Kubernetes manifests
│   ├── helm/                            # Helm charts
│   │   └── infra/                       # Infrastructure Helm chart
│   │       ├── Chart.yaml               # Helm chart metadata (no dependencies)
│   │       ├── values.yaml              # Default values (AppProject config)
│   │       └── templates/
│   │           ├── namespaces.yaml
│   │           ├── rbac.yaml
│   │           ├── argocds.yaml
│   │           ├── app-projects.yaml
│   │           ├── operator-groups.yaml
│   │           ├── subscriptions.yaml
│   │           ├── external-secrets-stores.yaml
│   │           ├── hyperconverged.yaml
│   │           ├── checlusters.yaml
│   │           ├── mta.yaml
│   │           └── console-plugins.yaml
│   ├── plain/                           # Plain YAML manifests
│   │   └── openbao/                     # OpenBao supplementary resources
│   │       └── resources.yaml           # Namespace, ServiceAccount, Route
│   └── kustomize/                       # Kustomize overlays
│       └── applications/
│           ├── base/                    # Shared base (deploy + s2i)
│           └── <app-name>/              # Per-app overlay (deploy + s2i)
└── eap/                                 # EAP server configuration
    └── applications/
        └── mammoth-ear/                 # CLI scripts
```

## Deployment Order

The setup is a three-step manual process:

1. **Install OpenBao** (`oc apply -f gitops/infra/application-openbao.yaml`)
2. **Initialize OpenBao** (unseal, configure secrets engine, Kubernetes auth, create secrets)
3. **Install Infrastructure** (`oc apply -f gitops/infra/application-infra.yaml`)

This ordering ensures OpenBao is running and initialized before the infra app creates the ClusterSecretStore and ExternalSecrets that depend on it.

## Key Conventions

### ArgoCD Sync Waves

#### OpenBao Application (`application-openbao.yaml`)

No sync waves needed — ArgoCD applies Namespace resources before namespaced resources automatically.

#### Infra Application (`application-infra.yaml`)

- **Wave 0**: Core namespaces + RBAC + ArgoCD instances
- **Wave 2**: Application Projects (AppProjects)
- **Wave 3**: Operators (OperatorGroups, Subscriptions, ExternalSecretsConfig) + MTA secrets + NetworkPolicies
- **Wave 4**: ClusterSecretStore (connects ESO to OpenBao) + HyperConverged + CheCluster
- **Wave 5**: ExternalSecrets + Tackle (depend on ClusterSecretStore and operator CRDs)

**Important**: Always add `argocd.argoproj.io/sync-wave` annotations to new resources to ensure proper deployment order.

### Manifest Strategies

The repo uses three manifest strategies:

1. **Helm (remote)** — OpenBao chart from `https://openbao.github.io/openbao-helm` (v0.28.3), values inline in `application-openbao.yaml`
2. **Helm (Git)** — Infrastructure chart at `manifests/helm/infra` (namespaces, RBAC, operators, AppProjects, Dev Spaces, MTA, ClusterSecretStore)
3. **Plain YAML** — OpenBao supplementary resources at `manifests/plain/openbao/` (Namespace, ServiceAccount, Route)
4. **Kustomize** (`manifests/kustomize/applications`): Application workloads — WildFly servers, build configs, external secrets. Uses base/overlay pattern with per-app overlays.

### OpenBao (Multi-Source Application)

`application-openbao.yaml` uses ArgoCD's multi-source pattern:
- **Source 1**: OpenBao Helm chart from `https://openbao.github.io/openbao-helm` with `releaseName: openbao` (ensures Service/StatefulSet are named `openbao`, matching ClusterSecretStore and Route references)
- **Source 2**: Supplementary plain manifests from `manifests/plain/openbao/` (Namespace, ServiceAccount for ESO auth, Route)

After deployment, the server must be manually initialized and unsealed (see README).

### Helm Templating

The `manifests/helm/infra` chart uses Helm templating to make infrastructure configurable:

1. **values.yaml**: Contains AppProject settings
2. **ArgoCD Application parameters**: Override values.yaml settings via `helm.parameters` in Application manifests

#### Parameterized Resources

The following resources are configured via `values.yaml`:

- **Namespaces**: Dynamic list in `namespaces` array (application namespaces only), passed as `helm.parameters` from `application-infra.yaml`
- **AppProject destinations**: `appProjects.sharedAppProject.destinations`
- **AppProject namespace blacklist**: `appProjects.sharedAppProject.namespaceResourceBlacklist`
- **AppProject source repos**: `appProjects.sharedAppProject.sourceRepos`
- **Developer groups**: `appProjects.sharedAppProject.roles.developerGroups`

#### Passing Parameters from ArgoCD

In `gitops/infra/application-infra.yaml`, namespace parameters are passed as arrays:

```yaml
helm:
  parameters:
    - name: namespaces[0]
      value: my-app-s2i
    - name: namespaces[1]
      value: my-app-deploy
```

### Namespace Management

Three types of namespaces:

1. **OpenBao namespace** (in `manifests/plain/openbao/resources.yaml`, deployed by OpenBao app):
   - `openbao`

2. **Infrastructure namespaces** (hardcoded in `manifests/helm/infra/templates/namespaces.yaml`):
   - `external-secrets-operator`
   - `openshift-logging`
   - `openshift-cnv`
   - `openshift-devspaces`
   - `openshift-mta`

3. **Bootstrap namespaces** (in `install-gitops.yaml`, applied before ArgoCD):
   - `openshift-gitops-operator`

4. **Application namespaces** (configurable via ArgoCD parameters):
   - Passed as `helm.parameters` in `application-infra.yaml`
   - Currently none configured (add when deploying new applications)

## Working with This Repository

### Adding a New Namespace

1. Add to ArgoCD Application parameters in `gitops/infra/application-infra.yaml`:
```yaml
- name: namespaces[N]
  value: new-namespace-name
```

2. The namespace will be created with sync wave "0"

### Adding a New AppProject Destination

1. Edit `manifests/helm/infra/values.yaml`:
```yaml
appProjects:
  sharedAppProject:
    destinations:
      - namespace: 'new-namespace'
        server: 'https://kubernetes.default.svc'
```

### Adding a New Operator

1. Create OperatorGroup if needed in `templates/operator-groups.yaml`
2. Create Subscription in `templates/subscriptions.yaml`
3. Add sync wave "3" annotation to both
4. Ensure the target namespace exists (add to namespaces if needed)

### Adding a New EAP Application

1. Add EAP config scripts under `eap/applications/<app-name>/`
2. Create Kustomize overlay under `manifests/kustomize/applications/<app-name>/` (with `deploy/` and `s2i/` subdirectories)
3. Create app-of-apps structure under `gitops/applications/<app-name>/`
4. Add the application namespaces to `application-infra.yaml` parameters

### Updating OpenBao Version

1. Update `targetRevision` in the OpenBao source entry in `gitops/infra/application-openbao.yaml`
2. No local chart files to update — ArgoCD fetches directly from the Helm repo

### Modifying Sync Waves

When changing sync waves, consider dependencies:
- Namespaces must exist before resources in those namespaces
- RBAC should be established early
- Operators need namespaces and operator groups
- ClusterSecretStore needs both the ESO operator and a running OpenBao
- ExternalSecrets need the ClusterSecretStore
- Applications need operators to be ready

## ArgoCD Application Structure

### OpenBao Application (deployed first)

`application-openbao.yaml` uses multi-source to deploy OpenBao from its upstream Helm repo plus supplementary resources (Namespace, ServiceAccount, Route) from Git.

### Infrastructure Application (deployed after OpenBao init)

`application-infra.yaml` uses single-source pointing to the `manifests/helm/infra` Helm chart. Depends on OpenBao being initialized for the ClusterSecretStore and ExternalSecrets to work.

### Automated Sync Policy

Both Applications use automated sync with:
- `prune: true` - Remove resources not in Git
- `selfHeal: true` - Revert manual changes
- `CreateNamespace=true` - Allows namespace creation
- `ServerSideApply=true` - Allows applying CRs whose CRDs are being installed in the same sync

The infra Application additionally has:
- `SkipDryRunOnMissingResource=true` - Skip validation for CRDs not yet installed
- `retry` with exponential backoff - Operators in wave 3 need time to install CRDs before later wave CRs can be applied

## Important Files

- **gitops/install-gitops.yaml**: Bootstrap GitOps operator, RBAC, and console plugin
- **gitops/infra/application-openbao.yaml**: OpenBao application (multi-source: Helm repo + plain manifests)
- **gitops/infra/application-infra.yaml**: Infrastructure application (single-source: Helm chart from Git)
- **manifests/plain/openbao/resources.yaml**: OpenBao Namespace, ServiceAccount, Route
- **manifests/helm/infra/Chart.yaml**: Helm chart metadata (no dependencies)
- **manifests/helm/infra/values.yaml**: Default Helm values (AppProject config)
- **manifests/helm/infra/templates/**: Infrastructure Kubernetes resource templates
- **manifests/kustomize/applications/base/**: Shared Kustomize base for EAP apps

## Best Practices

1. **Always use templates**: Don't hardcode values that might change per environment
2. **Use sync waves**: Ensure proper resource ordering within each Application
3. **Parameterize via ArgoCD**: Override Helm values through Application parameters, not by modifying values.yaml directly
4. **Test changes**: Verify Helm rendering with `helm template` before committing
5. **Document sync wave changes**: Update this file when adding new resource types
6. **Follow namespace patterns**: Infrastructure namespaces are hardcoded, application namespaces are parameterized
7. **Use multi-source for external charts**: External Helm charts (like OpenBao) are referenced directly in the ArgoCD Application's `sources:` array
8. **Deploy in order**: OpenBao must be deployed and initialized before the infra Application

## Common Commands

```bash
# Render Helm chart locally
helm template manifests/helm/infra

# Render with custom values
helm template manifests/helm/infra --set namespaces[0]=test-namespace

# Validate ArgoCD applications
kubectl apply --dry-run=client -f gitops/infra/application-openbao.yaml
kubectl apply --dry-run=client -f gitops/infra/application-infra.yaml
```
