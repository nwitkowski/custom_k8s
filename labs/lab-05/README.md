# Lab 5: ConfigMaps and Secrets
### Externalizing Configuration and Managing Sensitive Data
**Intermediate Kubernetes — Module 5 of 13**

---

## Lab Overview

### What You Will Do

- Create ConfigMaps from literals and files; consume as env vars and volume mounts
- Create Secrets (Opaque, TLS) and consume as env vars and volume mounts
- Mark ConfigMaps as immutable and observe update rejection
- Combine ConfigMap, Secret, and Downward API data using projected volumes
- *Optional:* Sync secrets from HashiCorp Vault using External Secrets Operator

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured  |  **Duration:** ~30-40 minutes

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-05
export STUDENT_NAME=<usernumber>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

---

## Step 1: Create ConfigMaps from Literals and Files

Create a namespace and a ConfigMap using literal key-value pairs:

```bash
kubectl create namespace lab05-$STUDENT_NAME

kubectl create configmap app-config \
    --from-literal=APP_ENV=production \
    --from-literal=APP_LOG_LEVEL=info \
    --from-literal=APP_MAX_CONNECTIONS=100 \
    --from-literal=APP_CACHE_TTL=3600 \
    -n lab05-$STUDENT_NAME

kubectl get configmap app-config -n lab05-$STUDENT_NAME -o yaml
```

Now create configuration files and load them into a ConfigMap. The `nginx.conf` file is static, while `app.properties` contains your student name:

```bash
cp nginx.conf /tmp/nginx.conf
envsubst '$STUDENT_NAME' < app.properties > /tmp/app.properties

kubectl create configmap app-files \
    --from-file=nginx.conf=/tmp/nginx.conf \
    --from-file=app.properties=/tmp/app.properties \
    -n lab05-$STUDENT_NAME
```

---

## Step 2: Consume ConfigMap as Environment Variables

### Using envFrom (inject all keys)

<!-- Creates a pod that imports all ConfigMap keys as env vars -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-envfrom.yaml | kubectl apply -f -
kubectl logs env-from-demo -n lab05-$STUDENT_NAME | grep APP_
```

### Using valueFrom (inject specific keys with renaming)

<!-- Creates a pod that selectively maps ConfigMap keys to different env var names -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-valuefrom.yaml | kubectl apply -f -
kubectl logs value-from-demo -n lab05-$STUDENT_NAME
```

> ✅ **Checkpoint:** Output is `Env=production Log=info`.

---

## Step 3: Consume ConfigMap as Volume Mounts

Mount the configuration files into an nginx container:

<!-- Creates a pod with ConfigMap data mounted as files -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-volume-mount.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/volume-mount-demo \
    -n lab05-$STUDENT_NAME --timeout=60s

kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/nginx/conf.d/default.conf
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/app/app.properties
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    curl -s http://localhost/health
```

> ✅ **Checkpoint:** The health endpoint returns `OK`.

---

## Step 4: Create Secrets

### Create an Opaque Secret

```bash
kubectl create secret generic db-credentials \
    --from-literal=DB_USERNAME=app_user \
    --from-literal=DB_PASSWORD='S3cur3P@ssw0rd!' \
    --from-literal=DB_HOST=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local \
    -n lab05-$STUDENT_NAME

kubectl get secret db-credentials -n lab05-$STUDENT_NAME \
    -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### Create a TLS Secret

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout tls.key -out tls.crt \
    -subj "/CN=app.lab05-$STUDENT_NAME.local/O=Lab"

kubectl create secret tls app-tls \
    --cert=tls.crt \
    --key=tls.key \
    -n lab05-$STUDENT_NAME
```

---

## Step 5: Consume Secrets as Env Vars and Volume Mounts

### Secret as Environment Variables

<!-- Creates a pod that reads Secret keys into env vars -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-secret-env.yaml | kubectl apply -f -
kubectl logs secret-env-demo -n lab05-$STUDENT_NAME
```

### Secret as Volume Mount

<!-- Creates a pod that mounts a Secret as files with restricted permissions -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-secret-volume.yaml | kubectl apply -f -
kubectl logs secret-vol-demo -n lab05-$STUDENT_NAME
kubectl exec secret-vol-demo -n lab05-$STUDENT_NAME -- cat /etc/db-creds/DB_USERNAME
```

> ✅ **Checkpoint:** Secret files are mounted with `0400` permissions. (A plain `ls -l` shows the keys as `lrwxrwxrwx` symlinks — that's Kubernetes' atomic-writer layout; the `0400` applies to the real files they point to, which `ls -lL` dereferences to.)

---

## Step 6: Immutable ConfigMaps

Kubernetes allows ConfigMaps to be marked as **immutable** — once set, neither the data nor the `immutable` flag can be changed. This protects production configuration from accidental edits and lets the kubelet skip watch overhead.

Apply the immutable ConfigMap:

```bash
envsubst '$STUDENT_NAME' < immutable-config.yaml | kubectl apply -f -
```

Inspect the ConfigMap and confirm it is immutable:

```bash
kubectl get configmap immutable-app-config -n lab05-$STUDENT_NAME -o yaml
```

> Note the `immutable: true` field and the two data keys: `APP_VERSION` and `FEATURE_FLAGS`.

Now attempt to update a value:

```bash
kubectl patch configmap immutable-app-config -n lab05-$STUDENT_NAME \
    --type merge -p '{"data":{"APP_VERSION":"3.0.0"}}'
```

> ✅ **Checkpoint:** The patch command is rejected with an error indicating the ConfigMap is immutable. To change an immutable ConfigMap you must delete and recreate it.

---

## Step 7: Projected Volumes

A **projected volume** combines multiple sources — ConfigMaps, Secrets, and the Downward API — into a single mount point. This is useful when a container needs configuration from several origins under one directory.

Apply the projected-volume pod:

```bash
envsubst '$STUDENT_NAME' < pod-projected.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/projected-demo \
    -n lab05-$STUDENT_NAME --timeout=60s
```

List the contents of the projected mount and verify each source:

```bash
# ConfigMap value (from app-config)
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/APP_ENV

# Secret value (from db-credentials)
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/DB_USERNAME

# Downward API values
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/namespace
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/labels
```

> ✅ **Checkpoint:** `APP_ENV` returns `production`, `DB_USERNAME` returns `app_user`, and `namespace` returns `lab05-<usernumber>`. All four files coexist under `/etc/projected`.

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 8: Sync Secrets from Vault with External Secrets Operator

The cluster has HashiCorp Vault and the External Secrets Operator (ESO) pre-installed. ESO watches for `ExternalSecret` resources and automatically syncs secrets from Vault into native Kubernetes Secrets.

#### Verify the Platform Components

```bash
# Check Vault is running
kubectl get pods -n vault

# Check ESO is running
kubectl get pods -n external-secrets

# Check the ClusterSecretStore is available
kubectl get clustersecretstore vault-store
```

> ✅ **Checkpoint:** The `vault-store` ClusterSecretStore should show `Ready` status.

#### Create an ExternalSecret

Review `external-secret.yaml` — it defines an ExternalSecret that pulls database credentials from Vault's `prod/database` path:

```bash
envsubst '$STUDENT_NAME' < external-secret.yaml | kubectl apply -f -
```

#### Verify the Synced Secret

```bash
# Check ExternalSecret status (should show SecretSynced)
kubectl get externalsecret db-external -n lab05-$STUDENT_NAME

# View the Kubernetes Secret that ESO created
kubectl get secret db-from-vault -n lab05-$STUDENT_NAME

# Decode the synced values
kubectl get secret db-from-vault -n lab05-$STUDENT_NAME \
    -o jsonpath='{.data.DB_USERNAME}' | base64 -d
echo

kubectl get secret db-from-vault -n lab05-$STUDENT_NAME \
    -o jsonpath='{.data.DB_HOST}' | base64 -d
echo
```

> ✅ **Checkpoint:** The `db-from-vault` Secret should contain `DB_USERNAME=appuser`, `DB_PASSWORD`, and `DB_HOST=db.internal.local` — matching the values seeded in Vault during cluster setup.

---

## Clean Up

```bash
kubectl delete namespace lab05-$STUDENT_NAME
rm -f tls.key tls.crt /tmp/nginx.conf /tmp/app.properties
```

---

## Summary

- **ConfigMaps:** Created from literals and files; consumed via `envFrom`, `valueFrom`, and volume mounts
- **Immutable ConfigMaps:** Prevent accidental changes to production configuration; must be deleted and recreated to update
- **Secrets:** Same consumption patterns as ConfigMaps; base64-encoded, not encrypted by default; use RBAC to restrict access and enable KMS encryption at rest
- **Projected Volumes:** Combine ConfigMap, Secret, and Downward API sources into a single mount point
- **External Secrets:** ESO syncs secrets from Vault into native Kubernetes Secrets via `ExternalSecret` CRDs — no secret values stored in Git

---

*Lab 5 Complete — Up Next: Lab 6 — Ingress and Gateway API*
