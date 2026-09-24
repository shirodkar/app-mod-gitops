# App Modernization GitOps

GitOps repository for deploying application modernization infrastructure and EAP workloads on OpenShift using ArgoCD.

## Prerequisites

- OpenShift cluster with cluster-admin access
- `oc` CLI logged in as cluster admin

## Setup

### 1. Install GitOps Operator

```bash
oc apply -f gitops/install-gitops.yaml
oc get pods -n openshift-gitops --watch
```

### 2. Deploy Infrastructure (Helm)

```bash
oc apply -f gitops/infra/application-infra.yaml
oc patch console.operator.openshift.io cluster --type=json -p '[{"op":"add","path":"/spec/plugins/-","value":"gitops-plugin"}]'
oc get applications -n openshift-gitops -w
```

### 3. Deploy OpenBao Vault

```bash
oc apply -f gitops/infra/application-openbao.yaml
oc get pods -n openbao --watch
```

Initialize and unseal:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao operator init -key-shares=1 -key-threshold=1'
oc exec -n openbao openbao-0 -- sh -c 'bao operator unseal <unseal_key>'
```

Configure secrets engine and Kubernetes auth:

```bash
oc exec -n openbao openbao-0 -- sh -c 'export BAO_TOKEN=<root_token> && bao secrets enable -version=1 -path=kv kv && bao auth enable kubernetes && bao write auth/kubernetes/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT && printf "path \"kv/*\" { capabilities = [\"read\",\"list\"] }" | bao policy write eso-policy - && bao write auth/kubernetes/role/eso-role bound_service_account_names=openbao-eso-auth bound_service_account_namespaces=openbao policies=eso-policy ttl=1h && bao write kv/secrets/ai API_KEY="<llm-api-key>"'
```

Add application secrets as needed via the OpenBao CLI or UI.

Access the OpenBao UI:

```bash
oc get route -n openbao
```

MTA is included in the infrastructure Helm chart (step 2) and deploys automatically.

### 4. Add the Mammoth Application to MTA

```
+-----------+      +---------+       +----------------+
|Application|──────|Archetype|───────|Analysis Profile|
+-----------+      +---------+       +----------------+
```

```bash
CLUSTER_URL_SUFFIX=$(oc whoami -c | sed -E 's|[^/]+/api-([^:]+):[0-9]+/.*|\1|')
HUB="https://mta-openshift-mta.apps.$CLUSTER_URL_SUFFIX/hub"

EAP_TAG_ID=$(curl -sk "$HUB/tags" | jq '[.[] | select(.name=="EAP" and .category.name=="Runtime")][0].id')
if [ "$EAP_TAG_ID" = "null" ] || [ -z "$EAP_TAG_ID" ]; then
  echo "ERROR: EAP tag not found"; exit 1
fi
echo "EAP_TAG_ID=$EAP_TAG_ID"

AP_ID=$(curl -sk -X POST "$HUB/analysis/profiles" \
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
echo "AP_ID=$AP_ID"

curl -sk -X POST "$HUB/applications" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Mammoth\",
    \"repository\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/mammoth-ear.git\"},
    \"tags\": [{\"id\": $EAP_TAG_ID}]
  }"

ARCH_ID=$(curl -sk -X POST "$HUB/archetypes" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"eap7\",
    \"criteria\": [{\"id\": $EAP_TAG_ID}]
  }" | jq '.id')
echo "ARCH_ID=$ARCH_ID"

curl -sk -X PUT "$HUB/archetypes/$ARCH_ID" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"eap7\",
    \"criteria\": [{\"id\": $EAP_TAG_ID}],
    \"profiles\": [{
      \"name\": \"eap8\",
      \"analysisProfile\": {\"id\": $AP_ID}
    }]
  }"
```

Dev Spaces is also included in the infrastructure Helm chart (step 2) and deploys automatically.

## Repository Structure

| Directory                           | Strategy    | Purpose                                                   |
| ----------------------------------- | ----------- | --------------------------------------------------------- |
| `gitops/install-gitops.yaml`        | Plain       | Bootstrap GitOps operator + RBAC                          |
| `gitops/infra/`                     | ArgoCD Apps | Infrastructure application definitions                    |
| `gitops/applications/`              | ArgoCD Apps | App-of-apps for each EAP workload                         |
| `manifests/helm/infra/`             | Helm        | Namespaces, RBAC, operators, AppProjects, Dev Spaces, MTA |
| `manifests/kustomize/applications/` | Kustomize   | EAP app workloads (base + per-app overlays)               |
| `manifests/plain/`                  | Plain YAML  | OpenBao supplementary resources                           |
| `eap/applications/`                 | —           | EAP server CLI scripts and module configs                 |
