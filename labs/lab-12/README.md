# Lab 12: Helm and Templating
### Package Management for Kubernetes
**Intermediate Kubernetes — Module 12 of 13**

---

## Lab Overview

### Objectives

- Install and manage Helm charts from repositories
- Upgrade and rollback releases
- Create a custom Helm chart with templating
- Validate, debug, and package charts

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured. Helm installed.
- Access to a Kubernetes cluster (EKS)

> **Duration:** ~45 minutes

---

## Environment Setup

```bash
cd ~/environment/custom_k8s/labs/lab-12
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** Your `$STUDENT_NAME` ensures your resources don't conflict with other students.

---

## Step 1: Verify Helm and Add Repository

```bash
helm version

helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update

helm search repo podinfo
helm show chart podinfo/podinfo
```

> If `helm` is not found: `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`

---

## Step 2: Install a Chart

```bash
kubectl create namespace helm-lab-$STUDENT_NAME

helm install my-podinfo podinfo/podinfo \
  --namespace helm-lab-$STUDENT_NAME \
  --set replicaCount=2 \
  --set service.type=ClusterIP

kubectl get pods -n helm-lab-$STUDENT_NAME -w
```

---

## Step 3: Explore the Release

```bash
helm list -n helm-lab-$STUDENT_NAME

helm get values my-podinfo -n helm-lab-$STUDENT_NAME

helm get values my-podinfo -n helm-lab-$STUDENT_NAME --all

helm get manifest my-podinfo -n helm-lab-$STUDENT_NAME
```

---

## Step 4: Upgrade the Release

```bash
helm upgrade my-podinfo podinfo/podinfo \
  --namespace helm-lab-$STUDENT_NAME \
  --set replicaCount=3 \
  --set service.type=ClusterIP

helm list -n helm-lab-$STUDENT_NAME
kubectl get pods -n helm-lab-$STUDENT_NAME
```

> ⚠️ When using `--set` during upgrade, previous values are **not** preserved unless you include them again or use `--reuse-values`.

---

## Step 5: Release History and Rollback

```bash
helm history my-podinfo -n helm-lab-$STUDENT_NAME

helm rollback my-podinfo 1 -n helm-lab-$STUDENT_NAME

helm list -n helm-lab-$STUDENT_NAME
kubectl get pods -n helm-lab-$STUDENT_NAME

helm history my-podinfo -n helm-lab-$STUDENT_NAME
```

> ✅ After rollback, the release is at `REVISION: 3` with 2 replicas. A rollback creates a new revision.

---

## Step 6: Create a Custom Chart

```bash
helm create mychart

find mychart/ -type f | sort
```

Examine the chart metadata and templates:

```bash
cat mychart/Chart.yaml
cat mychart/values.yaml
cat mychart/templates/deployment.yaml
cat mychart/templates/_helpers.tpl
```

---

## Step 7: Customize Templates

Create a ConfigMap template. Save as `mychart/templates/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "mychart.fullname" . }}-config
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
data:
  APP_ENV: {{ .Values.appConfig.environment | quote }}
  APP_LOG_LEVEL: {{ .Values.appConfig.logLevel | quote }}
  {{- if .Values.appConfig.customMessage }}
  CUSTOM_MESSAGE: {{ .Values.appConfig.customMessage | quote }}
  {{- end }}
```

Add to the end of `mychart/values.yaml`:

```yaml
appConfig:
  environment: production
  logLevel: info
  customMessage: "Hello from Helm!"
```

Add an `envFrom` to the container in `mychart/templates/deployment.yaml` so the pod loads the ConfigMap. Indentation here is unforgiving, so insert it with this command — it places the block right after `imagePullPolicy:` at the correct indent:

```bash
perl -i -pe 's/^(\s*imagePullPolicy:.*)$/$1\n          envFrom:\n            - configMapRef:\n                name: {{ include "mychart.fullname" . }}-config/' mychart/templates/deployment.yaml
```

This inserts (note `envFrom:` aligns with `image:`/`ports:` at 10 spaces):

```yaml
          envFrom:
            - configMapRef:
                name: {{ include "mychart.fullname" . }}-config
```

> ⚠️ Verify it before moving on: `helm lint mychart/` should pass, and `helm template r mychart/ | grep -A2 envFrom` should show the block. If you edit by hand instead, `envFrom:` must align with `image:`/`ports:`.

---

## Step 8: Validate and Debug

```bash
helm lint mychart/

helm template my-release mychart/

helm template my-release mychart/ --set appConfig.environment=staging

helm install my-release mychart/ \
  --namespace helm-lab-$STUDENT_NAME \
  --dry-run --debug
```

---

## Step 9: Package and Install Custom Chart

```bash
helm package mychart/

helm install my-custom-app mychart-0.1.0.tgz \
  --namespace helm-lab-$STUDENT_NAME \
  --set appConfig.environment=development \
  --set appConfig.logLevel=debug

helm list -n helm-lab-$STUDENT_NAME
kubectl get all -n helm-lab-$STUDENT_NAME -l app.kubernetes.io/instance=my-custom-app
```

Verify the ConfigMap and environment variables:

```bash
kubectl describe configmap my-custom-app-mychart-config -n helm-lab-$STUDENT_NAME

kubectl exec -n helm-lab-$STUDENT_NAME \
  $(kubectl get pod -n helm-lab-$STUDENT_NAME -l \
    app.kubernetes.io/instance=my-custom-app \
    -o jsonpath='{.items[0].metadata.name}') \
  -- env | grep -E "APP_|CUSTOM"
```

> ✅ Should show `APP_ENV=development`, `APP_LOG_LEVEL=debug`, `CUSTOM_MESSAGE=Hello from Helm!`

---

## Step 10: Clean Up

```bash
helm uninstall my-podinfo -n helm-lab-$STUDENT_NAME
helm uninstall my-custom-app -n helm-lab-$STUDENT_NAME
kubectl delete namespace helm-lab-$STUDENT_NAME
rm -rf mychart/ mychart-*.tgz
```

---

## Key Takeaways

- **Helm Repositories** -- add, search, and install charts from community registries
- **Release Management** -- install, upgrade, rollback with full revision history
- **Custom Charts** -- scaffold and organize chart templates with Go templating
- **Validation** -- lint, template, and dry-run before deploying

---

*Lab 12 Complete — Up Next: Lab 13 — CI/CD and GitOps*
