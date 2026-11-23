#!/bin/bash
set -e

HUB="https://$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}')/hub"
echo "HUB=$HUB"

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
  -d '{
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
}' | jq -r '.id')
echo "AP_EAP8_ID=$AP_EAP8_ID"

AP_QUARKUS_ID=$(curl -sk -X POST "$HUB/analysis/profiles" \
  -H "Content-Type: application/json" \
  -d '{
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
}' | jq -r '.id')
echo "AP_QUARKUS_ID=$AP_QUARKUS_ID"

# Create Mammoth EAR application (tagged EAP) with asset repository
curl -sk -X POST "$HUB/applications" \
  -H "Content-Type: application/json" \
  -d "{
  \"name\": \"Mammoth\",
  \"repository\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/mammoth-ear.git\"},
  \"assets\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/app-mod-gitops.git\", \"branch\": \"ocp5\", \"path\": \"manifests/mta-generated/replatform\"},
  \"tags\": [{\"id\": $EAP_TAG_ID}]
}"
echo ""

# Create Mammoth Backend application (tagged Quarkus) with asset repository
curl -sk -X POST "$HUB/applications" \
  -H "Content-Type: application/json" \
  -d "{
  \"name\": \"Mammoth Backend\",
  \"repository\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/mammoth-backend.git\"},
  \"assets\": {\"kind\": \"git\", \"url\": \"https://github.com/shirodkar/app-mod-gitops.git\", \"branch\": \"ocp5\", \"path\": \"manifests/mta-generated/refactor\"},
  \"tags\": [{\"id\": $QUARKUS_TAG_ID}]
}"
echo ""

# Create EAP archetype with EAP8 profile and generators
ARCH_EAP_ID=$(curl -sk -X POST "$HUB/archetypes" \
  -H "Content-Type: application/json" \
  -d "{
  \"name\": \"eap7-to-eap8\",
  \"criteria\": [{\"id\": $EAP_TAG_ID}],
  \"profiles\": [{\"name\": \"eap8\", \"analysisProfile\": {\"id\": $AP_EAP8_ID}}]
}" | jq '.id')
echo "ARCH_EAP_ID=$ARCH_EAP_ID"

# Create Quarkus archetype with Quarkus profile and generators
ARCH_QUARKUS_ID=$(curl -sk -X POST "$HUB/archetypes" \
  -H "Content-Type: application/json" \
  -d "{
  \"name\": \"eap8-to-quarkus\",
  \"criteria\": [{\"id\": $QUARKUS_TAG_ID}],
  \"profiles\": [{\"name\": \"quarkus\", \"analysisProfile\": {\"id\": $AP_QUARKUS_ID}}]
}" | jq '.id')
echo "ARCH_QUARKUS_ID=$ARCH_QUARKUS_ID"

echo ""
echo "MTA setup complete!"
