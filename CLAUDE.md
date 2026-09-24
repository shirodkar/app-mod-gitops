# CLAUDE.md

This file provides guidance to Claude Code when working with this GitOps repository.

## Project Overview

This is a **GitOps repository** for managing Kubernetes/OpenShift infrastructure and applications using **ArgoCD**. It deploys EAP (Enterprise Application Platform) workloads through an app-of-apps pattern, using a single Helm chart for all infrastructure (including OpenBao, operators, Dev Spaces, and MTA) and Kustomize for application workloads.

## Repository Structure

```
app-mod-gitops/
├── gitops/                              # ArgoCD Application definitions
│   ├── install-gitops.yaml              # Bootstrap: GitOps operator + RBAC
│   ├── infra/                           # Infrastructure applications
│   │   └── application-infra.yaml       # Single infra app (Helm, includes OpenBao subchart)
│   └── applications/                    # App-of-apps deployments (per EAP app)
│       └── <app-name>/
│           ├── application-of-apps.yaml
│           └── apps/
│               ├── deploy/              # Deploy-phase ArgoCD Application
│               └── s2i/                 # S2I build-phase ArgoCD Application
├── manifests/                           # Kubernetes manifests
│   ├── helm/                            # Helm charts
│   │   └── infra/                       # Infrastructure Helm chart
│   │       ├── Chart.yaml               # Includes OpenBao as subchart dependency
│   │       ├── Chart.lock
│   │       ├── values.yaml              # Default values (OpenBao + AppProject config)
│   │       ├── charts/                  # Subchart archives (openbao-0.28.3.tgz)
│   │       └── templates/
│   │           ├── namespaces.yaml
│   │           ├── rbac.yaml
│   │           ├── argocds.yaml
│   │           ├── app-projects.yaml
│   │           ├── operator-groups.yaml
│   │           ├── subscriptions.yaml
│   │           ├── openbao.yaml
│   │           ├── external-secrets-stores.yaml
│   │           ├── hyperconverged.yaml
│   │           ├── checlusters.yaml
│   │           ├── mta.yaml
│   │           └── console-plugins.yaml
│   └── kustomize/                       # Kustomize overlays
│       └── applications/
│           ├── base/                    # Shared base (deploy + s2i)
│           └── <app-name>/              # Per-app overlay (deploy + s2i)
└── eap/                                 # EAP server configuration
    └── applications/
        └── mammoth-ear/                 # CLI scripts
```

## Key Conventions

### ArgoCD Sync Waves

All infrastructure is deployed via a single ArgoCD Application (`application-infra.yaml`) with sync waves controlling the order:

- **Wave 0**: Core namespaces (including `openbao`) + RBAC + ArgoCD instances + OpenBao server (subchart)
- **Wave 2**: Application Projects (AppProjects)
- **Wave 3**: Operators (OperatorGroups, Subscriptions, ExternalSecretsConfig) + MTA secrets + NetworkPolicies
- **Wave 4**: ClusterSecretStore (connects ESO to OpenBao) + HyperConverged + CheCluster
- **Wave 5**: ExternalSecrets + Tackle + OpenBao Route (depend on ClusterSecretStore and operator CRDs)

**Important**: Always add `argocd.argoproj.io/sync-wave` annotations to new resources to ensure proper deployment order.

### Manifest Strategies

The repo uses two manifest strategies:

1. **Helm** (`manifests/helm/infra`): All infrastructure — OpenBao (subchart), namespaces, RBAC, operators, AppProjects, Dev Spaces, MTA, ClusterSecretStore. Single ArgoCD Application with `application-infra.yaml`.
2. **Kustomize** (`manifests/kustomize/applications`): Application workloads — WildFly servers, build configs, external secrets. Uses base/overlay pattern with per-app overlays.

### OpenBao Subchart

OpenBao is included as a Helm subchart dependency in `Chart.yaml`. Its configuration lives under the `openbao:` key in `values.yaml`. The subchart deploys the OpenBao server into the `openbao` namespace. After deployment, the server must be manually initialized and unsealed (see README).

### Helm Templating

The `manifests/helm/infra` chart uses Helm templating to make infrastructure configurable:

1. **values.yaml**: Contains OpenBao subchart config and AppProject settings
2. **ArgoCD Application parameters**: Override values.yaml settings via `helm.parameters` in Application manifests

#### Parameterized Resources

The following resources are configured via `values.yaml`:

- **OpenBao**: `openbao.*` — subchart configuration (server, storage, UI)
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

Two types of namespaces:

1. **Infrastructure namespaces** (hardcoded in templates):
   - `openbao` (in `openbao.yaml`)
   - `external-secrets-operator`
   - `openshift-logging`
   - `openshift-cnv`
   - `openshift-devspaces`
   - `openshift-mta`

2. **Bootstrap namespaces** (in `install-gitops.yaml`, applied before ArgoCD):
   - `openshift-gitops-operator`

3. **Application namespaces** (configurable via ArgoCD parameters):
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

1. Update the `version` in the `dependencies` section of `Chart.yaml`
2. Run `helm dependency update manifests/helm/infra` to pull the new chart archive
3. Commit the updated `Chart.yaml`, `Chart.lock`, and `charts/` directory

### Modifying Sync Waves

When changing sync waves, consider dependencies:
- Namespaces must exist before resources in those namespaces
- RBAC should be established early
- Operators need namespaces and operator groups
- ClusterSecretStore needs both the ESO operator and a running OpenBao
- ExternalSecrets need the ClusterSecretStore
- Applications need operators to be ready

## ArgoCD Application Structure

### Single Infrastructure Application

`application-infra.yaml` deploys everything via the `manifests/helm/infra` Helm chart, which includes the OpenBao subchart. This eliminates ordering issues between separate Applications.

### Automated Sync Policy

The infra Application uses automated sync with:
- `prune: true` - Remove resources not in Git
- `selfHeal: true` - Revert manual changes
- `SkipDryRunOnMissingResource=true` - Skip validation for CRDs not yet installed
- `ServerSideApply=true` - Allows applying CRs whose CRDs are being installed in the same sync
- `CreateNamespace=true` - Allows subchart to create its namespace
- `retry` with exponential backoff - Operators in wave 3 need time to install CRDs before later wave CRs (ClusterSecretStore, Tackle, CheCluster, HyperConverged) can be applied; retries handle this race

## Important Files

- **gitops/install-gitops.yaml**: Bootstrap GitOps operator, RBAC, and console plugin
- **gitops/infra/application-infra.yaml**: Single infrastructure application (Helm)
- **manifests/helm/infra/Chart.yaml**: Helm chart metadata with OpenBao subchart dependency
- **manifests/helm/infra/values.yaml**: Default Helm values (OpenBao + AppProject config)
- **manifests/helm/infra/templates/**: Infrastructure Kubernetes resource templates
- **manifests/kustomize/applications/base/**: Shared Kustomize base for EAP apps

## Best Practices

1. **Always use templates**: Don't hardcode values that might change per environment
2. **Use sync waves**: Ensure proper resource ordering
3. **Parameterize via ArgoCD**: Override Helm values through Application parameters, not by modifying values.yaml directly
4. **Test changes**: Verify Helm rendering with `helm template` before committing
5. **Document sync wave changes**: Update this file when adding new resource types
6. **Follow namespace patterns**: Infrastructure namespaces are hardcoded, application namespaces are parameterized
7. **Commit subchart archives**: The `charts/` directory must be committed so ArgoCD can render the subchart from Git

## Common Commands

```bash
# Render Helm chart locally
helm template manifests/helm/infra

# Render with custom values
helm template manifests/helm/infra --set namespaces[0]=test-namespace

# Update OpenBao subchart
helm dependency update manifests/helm/infra

# Validate ArgoCD application
kubectl apply --dry-run=client -f gitops/infra/application-infra.yaml
```
