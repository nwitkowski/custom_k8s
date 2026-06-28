# Lab 1: Exploring Your Kubernetes Cluster
### Hands-On Cluster Navigation and kubectl Fundamentals
**Intermediate Kubernetes — Module 1 of 13**

---

## Lab Overview

### Objectives

- Set up your AWS Cloud9 environment with required tools
- Connect to the shared EKS cluster
- Navigate cluster nodes, namespaces, and workloads
- Deploy, inspect, scale, and access an application

### Prerequisites

- AWS account credentials (provided by the instructor)

> ⏱ **Duration:** ~45 minutes

---

## Lab Parameters

> **Two regions, set by your class location.** Note them now — you use them throughout the labs:
>
> | Class location | Cloud9 region | Cluster region |
> |----------------|---------------|----------------|
> | **US** | `us-east-1` | `us-east-1` |
> | **Europe** | `eu-central-1` | `eu-west-3` |
>
> - **Cloud9 region** — where you create your Cloud9 IDE (Step 1, console region dropdown).
> - **Cluster region** — where the shared EKS cluster runs; you set it as `CLUSTER_REGION` (Step 4) and pass it to the setup script.
>
> For **US** classes the two regions are the same (`us-east-1`). For **Europe** classes they differ (Cloud9 in `eu-central-1`, cluster in `eu-west-3`); that cross-region setup is expected and supported, because the connection commands target the cluster region explicitly. Your instructor confirms the exact values.

---

## Step 1: Create Your Cloud9 Environment

1. Sign in to the **AWS Management Console** at [https://kiddcorp.signin.aws.amazon.com/console](https://kiddcorp.signin.aws.amazon.com/console) using your assigned **username** — your `usernumber` (e.g. `user01`) — and the password provided by the instructor
2. Set the region to your **Cloud9 region** (from Lab Parameters above) using the top-right dropdown
3. Search for **Cloud9** in the services search bar and open it
4. Click **Create environment**
5. Set **Name** to `k8s-lab-<usernumber>`
6. Set **Environment type** to New EC2 instance
7. Set **Instance type** to `m5.large`
8. Set **Platform** to Amazon Linux
9. Set **Network settings** to **SSH** (not SSM)
10. Set **VPC / Subnet** to defaults (or as directed by instructor)
11. Click **Create**
12. Wait 1-2 minutes for the status to show **Ready**, then click **Open** to launch the IDE

You will work in the Cloud9 terminal (bottom panel) for all labs.

> **Note:** Create the Cloud9 environment in your **Cloud9 region**. If the EKS cluster runs in a different **cluster region**, that cross-region setup is expected and not a problem — the connection commands in Step 4 target the cluster region explicitly via `CLUSTER_REGION`.

---

## Step 2: Attach IAM Role for EKS Access

Cloud9 managed credentials cannot access EKS. The `k8s-lab-role` IAM role was created automatically during cluster setup. Disable managed credentials and attach the role to your instance.

### Disable Cloud9 Managed Credentials

1. In the Cloud9 IDE, click the **gear icon** (top-right) or go to **Cloud9 → Preferences**
2. Expand **AWS Settings**
3. Turn **OFF** "AWS managed temporary credentials"

### Attach the Role to Your Instance

1. Open the **EC2 Console** in a new browser tab
2. Find your Cloud9 instance (named `aws-cloud9-k8s-lab-<usernumber>-...`)
3. Select the instance → **Actions → Security → Modify IAM role**
4. Choose `k8s-lab-role` → click **Update IAM role**

### Verify

```bash
aws sts get-caller-identity
```

> ✅ **Checkpoint:** The output should show the `k8s-lab-role` ARN.

---

## Step 3: Get the Lab Materials and Install Required Tools

### Get the Lab Materials

Clone the course repository into your Cloud9 workspace — every lab starts from a directory inside it:

```bash
cd ~/environment
git clone https://github.com/jwkidd3/custom_k8s.git
cd custom_k8s/labs/lab-01
```

> ⚠️ **Your identifier is your `usernumber`** — the exact username you signed in to AWS with (e.g. `user01`). Use it for everything: the Cloud9 environment name suffix (Step 1), and `STUDENT_NAME` in every lab. It keys all your namespaces, service accounts, and app names, and is already RFC&nbsp;1123-safe (lowercase letters, digits, hyphens; starts with a letter; ≤&nbsp;20 chars).

**Quick Setup:** Steps 3 and 4 can be automated with the setup script. After completing Step 2 and the clone above, run the following command (pass the **cluster region** from Lab Parameters as the second argument) and then skip to **Step 5**.

```bash
bash scripts/setup-cloud9.sh <usernumber> <cluster-region>   # e.g. bash scripts/setup-cloud9.sh user01 eu-west-3
```

### Manual Install

If you prefer to install each tool individually, follow the sections below.

### kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable-1.33.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Flux CLI

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
flux --version
```

### ArgoCD CLI

```bash
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/
argocd version --client
```

### jq and envsubst

```bash
# Amazon Linux 2
sudo yum install -y jq gettext

# Amazon Linux 2023 (if yum is not available)
# sudo dnf install -y jq gettext

jq --version
envsubst --version
```

> ⚠️ **Note:** `curl`, `git`, `openssl`, `sed`, and `docker` are pre-installed on Amazon Linux Cloud9 instances.

### Verify All Tools

```bash
echo "=== Tool Versions ==="
kubectl version --client --short 2>/dev/null || kubectl version --client
helm version --short
flux --version
argocd version --client --short 2>/dev/null || argocd version --client
jq --version
envsubst --version
git --version
docker --version
openssl version
```

> ✅ **Checkpoint:** All commands should return version information without errors.

---

## Step 4: Connect to the Shared EKS Cluster

Set the **cluster region** (from Lab Parameters) and connect. Export `CLUSTER_REGION` in each new terminal session — the labs reuse it wherever a region is needed:

```bash
export CLUSTER_REGION=<cluster-region>   # e.g. eu-west-3 — matches the Terraform aws_region

aws eks update-kubeconfig \
  --name platform-lab \
  --region "$CLUSTER_REGION"
```

Set `STUDENT_NAME` to your **usernumber** (the same username you logged in with — and gave the setup script) and verify connectivity:

```bash
export STUDENT_NAME=<usernumber>
echo "Student: $STUDENT_NAME (cluster region: $CLUSTER_REGION)"

kubectl cluster-info
kubectl config current-context
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `STUDENT_NAME` ensures your resources don't conflict with others. Set this variable at the start of every lab session.

> ⚠️ **Troubleshooting:** If you see "Unable to connect to the server", verify credentials with `aws sts get-caller-identity` and re-run `aws eks update-kubeconfig`.

---

## Step 5: Explore Cluster Nodes

```bash
# List all nodes with extended information
kubectl get nodes -o wide

# Describe a specific node (replace with your node name)
kubectl describe node <NODE_NAME>

# View all labels on nodes
kubectl get nodes --show-labels

# Check for taints on nodes
kubectl describe node <NODE_NAME> | grep -A 5 "Taints:"
```

---

## Step 6: Explore Namespaces and Workloads

```bash
# List all namespaces
kubectl get namespaces

# List system components running in kube-system
kubectl get pods -n kube-system

# View all resources across all namespaces
kubectl get all -A
```

Map the cluster's plumbing to the architecture (the control plane is AWS-managed and not shown):

```bash
kubectl get pods -n kube-system -o wide
#   coredns      -> cluster DNS
#   kube-proxy   -> Service networking on each node
#   aws-node     -> the CNI plugin (Pod networking / IPs)
#   ebs-csi-*    -> the CSI driver (volume provisioning)

# The API surface the control plane exposes:
kubectl api-resources | head -20
```

> ✅ **Checkpoint:** You only see **worker-node** components — the kubelet runs them, and CNI/CSI/DNS/kube-proxy are the pluggable drivers. The **control plane** (API server, scheduler, controller-manager, etcd) is managed by AWS and isn't visible — exactly the control-plane-vs-nodes split from the Module 1 architecture primer.

---

## Step 7: Deploy Your First Application

```bash
# Create your personal namespace
kubectl create namespace lab01-$STUDENT_NAME
kubectl config set-context --current --namespace=lab01-$STUDENT_NAME

# Create an nginx deployment with 2 replicas
kubectl create deployment nginx-lab --image=nginx:1.25 --replicas=2

# Expose the deployment as a ClusterIP service
kubectl expose deployment nginx-lab --port=80 --target-port=80

# Verify resources were created
kubectl get all -n lab01-$STUDENT_NAME
```

> ✅ **Checkpoint:** You should see 2 pods in `Running` state, 1 deployment with `2/2` ready, and 1 ClusterIP service.

---

## Step 8: Examine Pod Details

```bash
# Get pod names
kubectl get pods -n lab01-$STUDENT_NAME

# Describe a pod (replace with actual pod name)
kubectl describe pod <POD_NAME> -n lab01-$STUDENT_NAME

# View logs from a pod
kubectl logs <POD_NAME> -n lab01-$STUDENT_NAME

# Execute a command inside the container
kubectl exec -it <POD_NAME> -n lab01-$STUDENT_NAME -- /bin/bash

# Inside the container, explore:
cat /etc/nginx/nginx.conf
curl localhost:80
exit
```

> ✅ **Checkpoint:** You should see the nginx welcome page HTML when running `curl localhost:80` from inside the container.

---

## Step 9: Scale the Deployment

```bash
# Scale up to 5 replicas
kubectl scale deployment nginx-lab --replicas=5 -n lab01-$STUDENT_NAME

# Watch pods come up in real-time (Ctrl+C to exit)
kubectl get pods -n lab01-$STUDENT_NAME -w

# Scale down to 2 replicas
kubectl scale deployment nginx-lab --replicas=2 -n lab01-$STUDENT_NAME

# Watch pods terminate
kubectl get pods -n lab01-$STUDENT_NAME -w
```

---

## Step 10: Access the Application

Use port-forwarding to access your service:

```bash
# Forward local port 8080 to the service port 80
kubectl port-forward service/nginx-lab 8080:80 -n lab01-$STUDENT_NAME
```

You can also click **Preview → Preview Running Application** in Cloud9 to view in the built-in browser. Or open a **second terminal tab** (click the `+` icon) and test with curl:

```bash
curl http://localhost:8080
curl -I http://localhost:8080
```

> ✅ **Checkpoint:** You should see the default nginx welcome page. Press `Ctrl+C` in the first terminal to stop port-forwarding when done.

---

## Step 11: Explore Resource Usage

```bash
kubectl top nodes
kubectl top pods -n lab01-$STUDENT_NAME
```

> ⚠️ **If kubectl top fails:** Check if metrics-server is running: `kubectl get pods -n kube-system | grep metrics-server`. If missing, skip this step.

---

## Step 12: Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace lab01-$STUDENT_NAME
```

> ✅ **Checkpoint:** The `lab01-$STUDENT_NAME` namespace should no longer appear in `kubectl get namespaces`.

---

## Summary

- `aws eks update-kubeconfig` connects kubectl to EKS using IAM authentication
- Namespaces provide logical isolation — always work in a dedicated namespace
- `describe`, `logs`, and `exec` are your core troubleshooting triad
- Deployments manage ReplicaSets which manage Pods
- Port-forward is a development tool; production uses Ingress or LoadBalancer services

---

*Lab 1 Complete — Up Next: Lab 2 — Configuring Autoscaling*
