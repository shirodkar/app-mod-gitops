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

### 2. Install OpenBao

```bash
oc apply -f gitops/infra/application-openbao.yaml
oc get pods -n openbao --watch
```

Wait for the `openbao-0` pod to show `1/1 Running`.

### 3. Initialize OpenBao Secrets

Initialize and unseal:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao operator init -key-shares=1 -key-threshold=1'
# Save the Unseal Key and Root Token from the output

oc exec -n openbao openbao-0 -- sh -c 'bao operator unseal <UNSEAL_KEY>'
```

Configure secrets engine, Kubernetes auth, and application secrets:

```bash
oc exec -n openbao openbao-0 -- sh -c '
  export BAO_TOKEN=<ROOT_TOKEN>

  # Enable KV secrets engine
  bao secrets enable -version=1 -path=kv kv

  # Enable Kubernetes auth
  bao auth enable kubernetes
  bao write auth/kubernetes/config \
    kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT

  # Create policy for ESO
  printf "path \"kv/*\" { capabilities = [\"read\",\"list\"] }" | \
    bao policy write eso-policy -

  # Create role for ESO service account
  bao write auth/kubernetes/role/eso-role \
    bound_service_account_names=openbao-eso-auth \
    bound_service_account_namespaces=openbao \
    policies=eso-policy \
    ttl=1h

  # Add application secrets
  bao write kv/secrets/ai API_KEY="<LLM_API_KEY>"
'
```

Access the OpenBao UI:

```bash
oc get route -n openbao
```

### 4. Install Infrastructure

Deploys operators, RBAC, Dev Spaces, MTA, ClusterSecretStore, and ExternalSecrets.

```bash
oc apply -f gitops/infra/application-infra.yaml
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"gitops-plugin"}]'
oc get applications -n openshift-gitops -w
```

### 5. Add the Mammoth Application to MTA

Wait for all MTA pods to be running:

```bash
oc get pods -n openshift-mta --watch
```

Then configure the application, archetype, and analysis profile:

```
+-----------+      +---------+       +----------------+
|Application|──────|Archetype|───────|Analysis Profile|
+-----------+      +---------+       +----------------+
```

```bash
HUB="https://$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}')/hub"

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

## Repository Structure

| Directory                  | Strategy    | Purpose                                                |
| -------------------------- | ----------- | ------------------------------------------------------ |
| `gitops/install-gitops.yaml` | Plain     | Bootstrap GitOps operator + RBAC                       |
| `gitops/infra/`            | ArgoCD Apps | OpenBao + infrastructure application definitions       |
| `manifests/plain/openbao/` | Plain       | OpenBao supplementary resources (Namespace, SA, Route) |
| `manifests/helm/infra/`   | Helm        | Infra: operators, RBAC, AppProjects, Dev Spaces, MTA   |

## Troubleshooting

### `oc exec` fails with webhook error

If `oc exec` returns an error about `devworkspace-webhookserver`, the Dev Spaces operator left a stale webhook. Remove it:

```bash
oc delete validatingwebhookconfiguration controller.devworkspace.io
```

The webhook is recreated when the Dev Spaces operator fully deploys during step 4.
