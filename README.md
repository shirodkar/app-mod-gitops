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

### 5. Install Trusted Profile Analyzer (TPA)

Update `gitops/infra/application-tpa.yaml` with your cluster's app domain:

```yaml
appDomain: .apps.<your-cluster-domain>
oidc:
  issuerUrl: https://sso.apps.<your-cluster-domain>/realms/trustify
```

Create the Keycloak realm and client for TPA:

1. Open the Keycloak admin console: `https://sso.apps.<your-cluster-domain>`
2. Create realm: **trustify**
3. Create client in the trustify realm:
   - Client ID: **trustify-ui**
   - Client type: **OpenID Connect**
   - Client authentication: **Off** (public client)
   - Valid redirect URIs: `https://server.apps.<your-cluster-domain>/*`
   - Web origins: `*`

Deploy TPA:

```bash
oc apply -f gitops/infra/application-tpa.yaml
```

Run the database migration (required on first install):

```bash
oc run tpa-migrate -n trustify --restart=Never \
  --image=registry.redhat.io/rhtpa/rhtpa-rhel10@sha256:0dbc8d3f314b0877fc7d63612df2db30ae6d1dd741fe85cc9a0c15977d06ea13 \
  --overrides='{"spec":{"serviceAccountName":"default","containers":[{"name":"tpa-migrate","image":"registry.redhat.io/rhtpa/rhtpa-rhel10@sha256:0dbc8d3f314b0877fc7d63612df2db30ae6d1dd741fe85cc9a0c15977d06ea13","command":["trustd","db","migrate"],"env":[{"name":"TRUSTD_DB_HOST","value":"tpa-db"},{"name":"TRUSTD_DB_PORT","value":"5432"},{"name":"TRUSTD_DB_NAME","value":"trustify"},{"name":"TRUSTD_DB_USER","value":"trustify"},{"name":"TRUSTD_DB_PASSWORD","value":"trustify123"},{"name":"TRUSTD_STORAGE_FS_PATH","value":"/tmp/storage"}],"volumeMounts":[{"name":"tmp","mountPath":"/tmp/storage"}]}],"volumes":[{"name":"tmp","emptyDir":{}}]}}'
```

Wait for the migration to complete, then clean up:

```bash
oc logs -f tpa-migrate -n trustify
oc delete pod tpa-migrate -n trustify
```

Restart pods if needed:

```bash
oc delete pods -n trustify -l app.kubernetes.io/component=importer
oc delete pods -n trustify -l app.kubernetes.io/component=server
```

TPA UI: `https://server.apps.<your-cluster-domain>`

### 6. Add Applications to MTA

Wait for all 6 MTA pods to show `1/1 Running`:

```bash
oc get pods -n openshift-mta --watch
```

Then configure the applications, archetypes, and analysis profiles:

```
+-----------+      +---------+       +----------------+
|Application|──────|Archetype|───────|Analysis Profile|
+-----------+      +---------+       +----------------+
```

Save and run the following script:

```bash
bash scripts/setup-mta.sh
```

The script is located at [`scripts/setup-mta.sh`](scripts/setup-mta.sh).

After the script completes, add generators to both archetypes via the MTA UI:

1. Navigate to **Archetypes** in MTA
2. Edit each archetype (`eap7-to-eap8` and `eap8-to-quarkus`)
3. Add generators: **Quickstart-Java-Service**, **Quickstart-OpenShift-GitOps**, **Quickstart-OpenShift-Pipelines**

### 7. Set up the Mammoth Application VM and Database VM on OpenShift Virtualization

```bash
oc apply -f gitops/applications/mammoth-ear/application-rehost.yaml
```

Wait for the 'rehost' ArgoCD application to be Synced and Healthy:

```bash
oc get applications -n openshift-gitops -w
```

### 8. Create Red Hat registry pull secret

```bash
oc create namespace cicd
oc create secret docker-registry rh-image-pull-secret \
  -n cicd \
  --docker-server=registry.redhat.io \
  --docker-username=<your-rh-username> \
  --docker-password=<your-rh-password>
```

### 9. Set up CICD and WildFly Server for the Mammoth Application on OpenShift

```bash
oc apply -f gitops/applications/mammoth-ear/application-replatform.yaml
```

Wait for the 'replatform' ArgoCD application to be Synced. It will show **Progressing** until the pipeline is run in the next step.

```bash
oc get applications -n openshift-gitops -w
```

### 10. Run the Replatform Pipeline

```bash
oc create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: replatform-mammoth-eap8-run-
  namespace: cicd
spec:
  pipelineRef:
    name: replatform-mammoth-eap8
  taskRunTemplate:
    serviceAccountName: tekton-builder
  workspaces:
    - name: shared-workspace
      persistentVolumeClaim:
        claimName: replatform-pipeline-pvc
    - name: registry-credentials
      secret:
        secretName: rh-image-pull-secret
EOF
```

### 11. Set up CICD and Deployment for the Mammoth Backend Microservice on OpenShift

```bash
oc apply -f gitops/applications/mammoth-ear/application-refactor.yaml
```

Wait for the 'refactor' ArgoCD application to be Synced. It will show **Progressing** until the pipeline is run in the next step.

```bash
oc get applications -n openshift-gitops -w
```

### 12. Run the Refactor Pipeline

```bash
oc create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: refactor-mammoth-backend-run-
  namespace: cicd
spec:
  pipelineRef:
    name: refactor-mammoth-backend
  taskRunTemplate:
    serviceAccountName: tekton-builder
  workspaces:
    - name: shared-workspace
      persistentVolumeClaim:
        claimName: refactor-pipeline-pvc
EOF
```

## Repository Structure

| Directory                                | Strategy    | Purpose                                                        |
| ---------------------------------------- | ----------- | -------------------------------------------------------------- |
| `gitops/install-gitops.yaml`             | Plain       | Bootstrap GitOps operator + RBAC                               |
| `gitops/infra/`                          | ArgoCD Apps | OpenBao, infrastructure, and TPA application definitions       |
| `gitops/applications/mammoth-ear/`       | ArgoCD Apps | Rehost, replatform, refactor, and GitLab app definitions       |
| `manifests/plain/openbao/`               | Plain       | OpenBao supplementary resources (Namespace, SA, Route)         |
| `manifests/plain/tpa/`                   | Plain       | TPA PostgreSQL database                                        |
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

### OpenBao is sealed / ClusterSecretStore shows "unable to create client" / 'infra' application shows Degraded status in ArgoCD

OpenBao seals itself whenever its pod restarts (node reboot, eviction, redeployment). Check and unseal:

```bash
oc exec -n openbao openbao-0 -- sh -c 'bao status'
oc exec -n openbao openbao-0 -- sh -c 'bao operator unseal <UNSEAL_KEY>'
```

If the root token has changed (permission denied when writing config), reconfigure Kubernetes auth:

```bash
oc exec -n openbao openbao-0 -- sh -c 'export BAO_TOKEN=<ROOT_TOKEN> && bao write auth/kubernetes/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT'
```

The ClusterSecretStore and ExternalSecrets will reconnect automatically once OpenBao is unsealed.

### Pipeline build fails with registry auth error

If buildah can't pull from `registry.redhat.io`, ensure the `rh-image-pull-secret` exists in the `cicd` namespace and is passed as the `registry-credentials` workspace in the PipelineRun.

### TPA importer crashes with "relation does not exist"

The database migration needs to run first. See step 5 for the migration command.
