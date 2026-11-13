# App Modernization GitOps

GitOps repository for deploying application modernization infrastructure and EAP workloads on OpenShift using ArgoCD.

## Prerequisites

- OpenShift cluster with cluster-admin access
- `oc` CLI logged in as cluster admin
- Create users - admin, developer, plateng

## Setup

### 1. Install GitOps Operator and Create Groups

```bash
oc apply -f gitops/install-gitops.yaml
oc adm groups new cluster-admins admin
oc adm groups new developers developer
oc adm groups new platengs plateng
```

Wait for all pods to be Ready

```bash
oc get pods -n openshift-gitops --watch
```

### 2. Install OpenBao

```bash
oc apply -f gitops/infra/application-openbao.yaml
```

Wait for the `openbao-0` pod to show `1/1 Running`:

```bash
oc get pods -n openbao --watch
```

### 3. Initialize OpenBao Secrets

Initialize and unseal:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao operator init -key-shares=1 -key-threshold=1'
```

Save the Unseal Key and Root Token from the output.
Unseal OpenBAO using the Unseal Key:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao operator unseal <UNSEAL_KEY>'
```

Configure secrets engine, Kubernetes auth, and application secrets:

```bash
oc exec -n openbao openbao-0 -- sh -c 'export BAO_TOKEN=<ROOT_TOKEN> && bao secrets enable -version=1 -path=kv kv && bao auth enable kubernetes && bao write auth/kubernetes/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT && printf "path \"kv/*\" { capabilities = [\"read\",\"list\"] }" | bao policy write eso-policy - && bao write auth/kubernetes/role/eso-role bound_service_account_names=openbao-eso-auth bound_service_account_namespaces=openbao policies=eso-policy ttl=1h && bao write kv/secrets/ai API_KEY="<LLM_API_KEY>"'
```

Wait for the 'openbao' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

To access the OpenBao UI:

```bash
oc get route -n openbao
```

### 4. Install Infrastructure

Deploys operators, RBAC, Dev Spaces, MTA, ClusterSecretStore, and ExternalSecrets.

```bash
oc apply -f gitops/infra/application-infra.yaml
```

Wait for the 'infra' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

### 5. Add Applications to MTA

Wait for all 6 MTA pods to be show `1/1 Running`:

```bash
oc get pods -n openshift-mta --watch
```

Then configure the applications, archetypes, and analysis profiles:

```
+-----------+      +---------+       +----------------+
|Application|──────|Archetype|───────|Analysis Profile|
+-----------+      +---------+       +----------------+
```

```bash
HUB="https://$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}')/hub"

# Get tag IDs
EAP_TAG_ID=$(curl -sk "$HUB/tags" | jq '[.[] | select(.name=="EAP" and .category.name=="Runtime")][0].id')
if [ "$EAP_TAG_ID" = "null" ] || [ -z "$EAP_TAG_ID" ]; then
  echo "ERROR: EAP tag not found"; exit 1
fi
QUARKUS_TAG_ID=$(curl -sk "$HUB/tags" | jq '[.[] | select(.name=="Quarkus" and .category.name=="Runtime")][0].id')
if [ "$QUARKUS_TAG_ID" = "null" ] || [ -z "$QUARKUS_TAG_ID" ]; then
  echo "ERROR: Quarkus tag not found"; exit 1
fi
echo "EAP_TAG_ID=$EAP_TAG_ID"
echo "QUARKUS_TAG_ID=$QUARKUS_TAG_ID"

# Create analysis profiles
AP_EAP8_ID=$(curl -sk -X POST "$HUB/analysis/profiles" \
  -H "Content-Type: application/json" \
  -d "$(cat <<'EOF'
{
  "name": "EAP7 to EAP8",
  "mode": {"withDeps": true},
  "scope": {"withKnownLibs": true, "packages": {"included": [], "excluded": []}},
  "rules": {
    "targets": [
      {"id": 1, "selection": "konveyor.io/target=eap8"},
      {"id": 6, "selection": "konveyor.io/target=openjdk17"},
      {"id": 8},
      {"id": 9}
    ],
    "labels": {"included": [], "excluded": []},
    "repository": {
      "kind": "git",
      "url": "https://github.com/shirodkar/mammoth-ear.git",
      "branch": "main",
      "path": "/rules/"
    }
  }
}
EOF
)" | jq -r '.id')
echo "AP_EAP8_ID=$AP_EAP8_ID"

AP_QUARKUS_ID=$(curl -sk -X POST "$HUB/analysis/profiles" \
  -H "Content-Type: application/json" \
  -d "$(cat <<'EOF'
{
  "name": "Quarkus",
  "mode": {"withDeps": true},
  "scope": {"withKnownLibs": true, "packages": {"included": [], "excluded": []}},
  "rules": {
    "targets": [
      {"id": 2},
      {"id": 5},
      {"id": 6, "selection": "konveyor.io/target=openjdk17"},
      {"id": 8},
      {"id": 9}
    ],
    "labels": {"included": [], "excluded": []}
  }
}
EOF
)" | jq -r '.id')
echo "AP_QUARKUS_ID=$AP_QUARKUS_ID"

# Create Mammoth EAR application (tagged EAP)
curl -sk -X POST "$HUB/applications" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Mammoth\",
    \"repository\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/mammoth-ear.git\"},
    \"tags\": [{\"id\": $EAP_TAG_ID}]
  }"

# Create Mammoth Backend application (tagged Quarkus)
curl -sk -X POST "$HUB/applications" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Mammoth Backend\",
    \"repository\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/mammoth-backend.git\"},
    \"tags\": [{\"id\": $QUARKUS_TAG_ID}]
  }"

# Create EAP archetype (matches EAP-tagged apps) with EAP8 profile
ARCH_EAP_ID=$(curl -sk -X POST "$HUB/archetypes" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"eap7-to-eap8\",
    \"criteria\": [{\"id\": $EAP_TAG_ID}],
    \"profiles\": [{
      \"name\": \"eap8\",
      \"analysisProfile\": {\"id\": $AP_EAP8_ID}
    }]
  }" | jq '.id')
echo "ARCH_EAP_ID=$ARCH_EAP_ID"

# Create Quarkus archetype (matches Quarkus-tagged apps) with Quarkus profile
ARCH_QUARKUS_ID=$(curl -sk -X POST "$HUB/archetypes" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"eap8-to-quarkus\",
    \"criteria\": [{\"id\": $QUARKUS_TAG_ID}],
    \"profiles\": [{
      \"name\": \"quarkus\",
      \"analysisProfile\": {\"id\": $AP_QUARKUS_ID}
    }]
  }" | jq '.id')
echo "ARCH_QUARKUS_ID=$ARCH_QUARKUS_ID"
```

### 6. Set up the Mammoth Application VM and Database VM on OpenShift Virtualization

```bash
oc apply -f gitops/applications/mammoth-ear/application-rehost.yaml
```

Wait for the 'rehost' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

### 7. Set up CICD and WildFly Server for the Mammoth Application on OpenShift

```bash
oc apply -f gitops/applications/mammoth-ear/application-replatform.yaml
```

Wait for the 'replatform' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

### 8. Manually add your pull secret to the 'cicd' namespace and name it 'rh-image-pull-secret'.

### 9. Set up CICD and Deployment for the Mammoth Backend Microservice on OpenShift

```bash
oc apply -f gitops/applications/mammoth-ear/application-refactor.yaml
```

Wait for the 'refactor' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

## Repository Structure

| Directory                                | Strategy    | Purpose                                                        |
| ---------------------------------------- | ----------- | -------------------------------------------------------------- |
| `gitops/install-gitops.yaml`             | Plain       | Bootstrap GitOps operator + RBAC                               |
| `gitops/infra/`                          | ArgoCD Apps | OpenBao + infrastructure application definitions               |
| `gitops/applications/mammoth-ear/`       | ArgoCD Apps | Rehost, replatform, refactor, and GitLab app definitions       |
| `manifests/plain/openbao/`               | Plain       | OpenBao supplementary resources (Namespace, SA, Route)         |
| `manifests/plain/gitlab/`               | Plain       | GitLab operator, subscription, and GitLab CR                   |
| `manifests/helm/infra/`                  | Helm        | Infra: operators, RBAC, AppProjects, Dev Spaces, MTA           |
| `manifests/helm/rehost/`                | Helm        | PostgreSQL VM and EAP8 VM on OpenShift Virtualization          |
| `manifests/helm/replatform/`             | Helm        | Mammoth EAP8 S2I build pipeline, WildFlyServer, and DB config  |
| `manifests/helm/refactor/`              | Helm        | Mammoth Backend Quarkus build pipeline and deployment           |

## Troubleshooting

### `oc exec` fails with webhook error

If `oc exec` returns an error about `devworkspace-webhookserver`, the Dev Spaces operator left a stale webhook. Remove it:

```bash
oc delete validatingwebhookconfiguration controller.devworkspace.io
```

The webhook is recreated when the Dev Spaces operator fully deploys during step 4.

### OpenBao is sealed / ClusterSecretStore shows "unable to create client / 'infra' application shows Degraded status in ArgoCD"

OpenBao seals itself whenever its pod restarts (node reboot, eviction, redeployment). Check and unseal:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao status'
oc exec -n openbao openbao-0 -- sh -c 'bao operator unseal <UNSEAL_KEY>'
```

The ClusterSecretStore and ExternalSecrets will reconnect automatically once OpenBao is unsealed.
