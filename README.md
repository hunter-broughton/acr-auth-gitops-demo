# Private ACR + GitOps Monitoring Demo

This repository drives one Arc-enabled kind cluster through one Azure-managed Microsoft Flux Git
source. Two Kustomizations deploy the same known-good private image; namespace membership in the
Private ACR Support extension's `acrMap` is the only authorization difference.

Canonical source: <https://github.com/hunter-broughton/acr-auth-gitops-demo>

| Kustomization | Namespace | `acrMap` | Expected Pod result |
| --- | --- | --- | --- |
| `mapped-workload` | `gitops-vision-a` | `acrvisiontrainkgw7x.azurecr.io` | Pulls and remains Ready |
| `unmapped-control` | `gitops-unmapped-control` | absent | `ImagePullBackOff` with Warning events |

Both Deployments use `acrvisiontrainkgw7x.azurecr.io/model-trainer:v1`, set
`imagePullPolicy: Always`, and omit `imagePullSecrets`. The extension owns the credential lifecycle
and injects `azure-arc-acr-pull` only into Pods created in the mapped namespace.

## Live topology

- Arc cluster: `hbroughton-acr-test-kind`
- Microsoft Flux extension: `microsoft.flux` `1.24.0`
- FluxConfiguration/GitRepository: `acr-auth-gitops-demo`
- Kustomizations: `mapped-workload` and `unmapped-control`
- Private ACR Support extension: `microsoft.test.authinjector` `0.1.18`, release train `merge`

The registered Private ACR Support installation command shown during the presentation is:

```powershell
az k8s-extension create `
  --subscription 0e750457-5252-493e-95a3-e40e6a460bf0 `
  --resource-group hbroughton-acr-auth-test `
  --cluster-name hbroughton-acr-test-kind `
  --cluster-type connectedClusters `
  --name acr-auth `
  --extension-type microsoft.test.authinjector `
  --release-train merge `
  --version 0.1.18 `
  --auto-upgrade-minor-version false `
  --configuration-settings acrMap.gitops-vision-a=acrvisiontrainkgw7x.azurecr.io
```

`gitops-unmapped-control` is deliberately absent from that command.

## Demo workflow

Run the one-time migration after committing this topology. It removes the old separate negative
FluxConfiguration and the demo FluxConfiguration from the retired second cluster, narrows the ACR
mapping, and recreates `acr-auth-gitops-demo` with exactly two Kustomizations:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Initialize
```

Reset to the empty two-tree baseline before presenting:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Prepare
```

Place the GitOps Monitoring blade beside the terminal, select `hbroughton-acr-test-kind`, and run:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Presenter
```

The presenter pauses twice:

1. Open `mapped-workload`, then continue and watch its Deployment, ReplicaSet, and healthy Pod
   appear.
2. Inspect the healthy tree, switch to `unmapped-control`, then continue and watch its Pod reach
   `ImagePullBackOff` while Warning events appear.

GitHub and Microsoft Flux remain the real desired-state path throughout. No Secret data is read or
displayed.

## Other actions

```powershell
# Validate tools, Azure topology, and the namespace mapping.
.\demo\Invoke-LiveDemo.ps1 -Action Preflight

# Publish only the mapped stage or the final negative stage.
.\demo\Invoke-LiveDemo.ps1 -Action Mapped
.\demo\Invoke-LiveDemo.ps1 -Action Negative

# Print current Azure, Flux, and workload state.
.\demo\Invoke-LiveDemo.ps1 -Action Status

# Print the extension installation command without changing anything.
.\demo\Invoke-LiveDemo.ps1 -Action ShowInstallCommand

# Return both resource trees to their no-Deployment baseline.
.\demo\Invoke-LiveDemo.ps1 -Action Cleanup
```

The detailed talk track is in [demo/FIVE-MINUTE-RUNBOOK.md](demo/FIVE-MINUTE-RUNBOOK.md), and the
machine-readable environment contract is in [demo/topology.json](demo/topology.json).