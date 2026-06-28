#!/bin/bash
###############################################################################
# Teardown the platform + cluster.
#
# A healthy, fully-applied stack destroys cleanly because the kubernetes/helm/
# flux providers can reach the live cluster. If the cluster API is already
# unreachable (half-built / stale state), the helm/k8s/flux/vault resources
# become un-destroyable phantoms — so on failure we remove those from state and
# destroy the remaining AWS infra. Re-runnable.
#
# Usage:  AWS_PROFILE=org-root bash teardown.sh
###############################################################################
set -uo pipefail
cd "$(dirname "$0")/terraform"

echo "==> Attempting clean destroy"
if terraform destroy -auto-approve -input=false; then
  echo "==> Destroy complete."
  exit 0
fi

echo "==> Clean destroy failed (likely cluster API unreachable). Removing cluster-API-bound resources from state, then destroying AWS infra."
for addr in \
  flux_bootstrap_git.this \
  helm_release.metrics_server \
  module.vault.helm_release.vault \
  module.vault.kubectl_manifest.vault_bootstrap \
  module.eks.kubernetes_annotations.remove_gp2_default \
  module.eks.kubernetes_storage_class.gp3_encrypted \
  module.eks.kubernetes_storage_class.gp3_encrypted_immediate \
  module.eks.kubernetes_storage_class.gp3_encrypted_retain \
  module.eks.kubernetes_storage_class.io2_encrypted; do
  terraform state rm "$addr" 2>/dev/null && echo "    removed $addr" || true
done

echo "==> Re-running destroy on remaining AWS resources"
terraform destroy -auto-approve -input=false
echo "==> Destroy complete (after state surgery)."
