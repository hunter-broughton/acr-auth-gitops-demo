# Five-Minute Private ACR + GitOps Monitoring Demo

## Story

One Arc cluster reconciles one GitHub source through the registered Microsoft Flux extension. The
source contains two Kustomizations that use the same private image:

- `mapped-workload` runs in `gitops-vision-a`, which is present in the extension's `acrMap`.
- `unmapped-control` runs in `gitops-unmapped-control`, which is absent from `acrMap`.

The first resource tree becomes healthy. The second reaches `ImagePullBackOff` and emits Warning
events. Cluster, source, registry, image, and workload shape stay fixed; only namespace authorization
changes.

## One-time migration

Commit and push the new repository topology before running:

```powershell
Set-Location C:\Users\t-hbroughton\Documents\Milestone-2\acr-auth-gitops-demo
.\demo\Invoke-LiveDemo.ps1 -Action Initialize
```

`Initialize` performs the live topology migration:

- Prints the complete `microsoft.test.authinjector` install command, including
  `acrMap.gitops-vision-a=acrvisiontrainkgw7x.azurecr.io`.
- Narrows the installed extension configuration to that mapped namespace.
- Deletes the old `acr-auth-negative-control` FluxConfiguration.
- Deletes the demo FluxConfiguration from the retired `acr-auth-demo` cluster.
- Recreates `acr-auth-gitops-demo` on `hbroughton-acr-test-kind` with only `mapped-workload` and
  `unmapped-control`.

## Before presenting

Run this 10 minutes before the meeting:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Prepare
```

`Prepare` publishes the baseline, waits for the exact Git revision on both Kustomizations, verifies
that both Deployments are absent, confirms the mapped namespace has `azure-arc-acr-pull`, confirms
the unmapped namespace does not, and clears prior negative-control events.

Arrange two windows:

1. GitOps Monitoring blade filtered to `hbroughton-acr-test-kind` and source
   `acr-auth-gitops-demo`.
2. A large PowerShell terminal in the repository root.

Start the presenter:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Presenter
```

## 0:00-1:00 - Establish the contract

The terminal prints the registered extension installation command:

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

Call out three details:

- This is a registered Arc extension installation, not a manually installed webhook.
- The map authorizes one namespace for one private registry.
- `gitops-unmapped-control` is not authorized.

In the blade, open `mapped-workload`. Its monitoring owner is
`acr-auth-gitops-demo-mapped-workload`. Press Enter.

## 1:00-2:45 - Watch the mapped tree become healthy

The script publishes `Demo: add mapped private ACR workload` and forces the one Microsoft Flux
source to reconcile the exact commit. Keep the mapped resource tree open and watch these resources
appear:

1. Deployment `vision-model-trainer`
2. ReplicaSet
3. Pod

The terminal proves:

- Git image: `acrvisiontrainkgw7x.azurecr.io/model-trainer:v1`
- Git `imagePullPolicy`: `Always`
- Git `imagePullSecrets`: absent
- Stored Deployment template pull Secret: absent
- Stored Pod pull Secret: `azure-arc-acr-pull`
- Pod: Ready after a real private pull

Refresh the tree once if Log Analytics ingestion has not caught up. Keep the mapped Pod visible long
enough to establish the healthy result, then switch to `unmapped-control`. Its monitoring owner is
`acr-auth-gitops-demo-unmapped-control`. Press Enter.

## 2:45-4:30 - Watch the unmapped tree fail

The script publishes `Demo: add unmapped private ACR control`. The mapped Deployment remains healthy
while the second Kustomization creates an otherwise equivalent Deployment using the same image.

Watch the unmapped tree add its Deployment, ReplicaSet, and Pod. The Pod transitions through
`ErrImagePull` to `ImagePullBackOff`.

The terminal proves:

- Namespace mapping: absent
- Namespace `azure-arc-acr-pull` Secret: absent
- Injected Pod pull Secret: absent
- Waiting reason: `ErrImagePull` or `ImagePullBackOff`
- Kubernetes Warning events: private registry authorization failure

The script prints Kubernetes events immediately. Monitoring Health should follow quickly; the
backend's polled Event category can arrive later than the five-minute slot, so do not wait on an
Event row to establish the negative result.

## 4:30-5:00 - Compare outcomes

Show both monitoring owners under the same Git source:

| Owner | Runtime result | Explanation |
| --- | --- | --- |
| `acr-auth-gitops-demo-mapped-workload` | Ready | Namespace is mapped; Secret is provisioned and injected |
| `acr-auth-gitops-demo-unmapped-control` | `ImagePullBackOff` | Namespace is unmapped; no Secret is provisioned or injected |

Close with: one desired-state source produced both outcomes, and GitOps Monitoring explains the
runtime difference without exposing credentials.

## After presenting

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Cleanup
```

`Cleanup` publishes the empty baseline and waits for Flux pruning. It preserves the cluster,
registered extensions, source, Kustomizations, namespaces, and extension-owned mapped Secret.

No action reads or displays Secret `.data`.