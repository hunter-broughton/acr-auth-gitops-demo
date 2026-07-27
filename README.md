# ACR Auth GitOps Demo

This repository drives two Arc-enabled kind clusters through Microsoft Flux. Each workload uses a
private ACR image with `imagePullPolicy: Always` and deliberately omits `imagePullSecrets`.

Canonical source: <https://github.com/hunter-broughton/acr-auth-gitops-demo>

| Cluster | Namespace | Registry | Workload |
| --- | --- | --- | --- |
| `hbroughton-acr-test-kind` | `gitops-vision-a` | `acrvisiontrainkgw7x.azurecr.io` | `vision-model-trainer` |
| `hbroughton-acr-test-kind` | `gitops-speech-a` | `acrspeechtrainkgw7x.azurecr.io` | `speech-model-trainer` |
| `acr-auth-demo` | `gitops-nlp-b` | `acrnlptrainkgw7x.azurecr.io` | `nlp-model-trainer` |
| `acr-auth-demo` | `gitops-vision-b` | `acrvisiontrainkgw7x.azurecr.io` | `vision-model-trainer` |

The optional fleet profile adds batch and canary variants in each mapped namespace. It expands the
same topology from four to twelve Deployments without adding credentials, registries, namespace
mappings, or Azure resources.

The namespace kustomizations reconcile first. Workload kustomizations depend on them, allowing the
ACR Auth SecretProvisioner to create `azure-arc-acr-pull` before the Deployments are enabled in the
second demo commit.

Each Arc cluster has one Microsoft Flux configuration with two Kustomizations:

| Cluster | Kustomization | Repository path | Dependency |
| --- | --- | --- | --- |
| `hbroughton-acr-test-kind` | `namespaces` | `./clusters/hbroughton-acr-test-kind/namespaces` | none |
| `hbroughton-acr-test-kind` | `workloads` | `./clusters/hbroughton-acr-test-kind/workloads` | `namespaces` |
| `acr-auth-demo` | `namespaces` | `./clusters/acr-auth-demo/namespaces` | none |
| `acr-auth-demo` | `workloads` | `./clusters/acr-auth-demo/workloads` | `namespaces` |

The first commit keeps each workload phase on a harmless ConfigMap. The second commit adds
`workloads.yaml` to the workload Kustomizations, making the four private-image Deployments visibly
Git-authored and Git-activated.

## Live demo environment

Both Arc-enabled kind clusters use registered Azure extensions rather than manually installed Flux
APIs:

| Cluster | Microsoft Flux | Azure Flux configuration | ACR Auth |
| --- | --- | --- | --- |
| `hbroughton-acr-test-kind` | `microsoft.flux` `1.24.0` | `acr-auth-gitops-demo` | `microsoft.test.authinjector` `0.1.18` |
| `acr-auth-demo` | `microsoft.flux` `1.24.0` | `acr-auth-gitops-demo` | `microsoft.test.authinjector` `0.1.18` |

The Microsoft Flux controllers and CRDs are installed by the `flux` Azure extension Helm release in
`flux-system`. The Azure Flux configurations reconcile this public repository over HTTPS and report
`Compliant`.

GitOps monitoring is installed on both clusters and exports to the same Log Analytics table while
preserving each cluster's distinct ARM resource ID. The monitoring producer recognizes the
Microsoft-managed labels and records `FluxConfigured=true` with configuration name
`acr-auth-gitops-demo`.

## Credential-free workload contract

- Git contains only Namespace, ConfigMap, and Deployment manifests.
- Deployment Pod templates contain no `imagePullSecrets`.
- Each mapped namespace receives the extension-owned `azure-arc-acr-pull` Secret.
- AuthInjector adds that Secret reference only to the stored Pod during CREATE admission.
- Every Deployment uses `imagePullPolicy: Always`, forcing a real private registry pull.
- ACR admin credentials, refresh tokens, and `.dockerconfigjson` are never committed or displayed.

The deployed Pods should be Ready and should show `azure-arc-acr-pull` in
`spec.imagePullSecrets`, while the corresponding Deployment templates remain empty.

## Five-minute live demo

The repeatable presenter automation and talk track are in:

- [`demo/Invoke-LiveDemo.ps1`](demo/Invoke-LiveDemo.ps1)
- [`demo/FIVE-MINUTE-RUNBOOK.md`](demo/FIVE-MINUTE-RUNBOOK.md)

Run `Initialize` once, `Prepare` before the meeting, `Presenter` on stage, and `Cleanup` afterward.
`Presenter` is a side-by-side terminal and GitOps Monitoring experience. The terminal uses six
concise AI model-training story modules, renders manifest proof, shows token rotation and Secret
recreation, and deploys through Microsoft Flux. The monitoring blade remains visible for resource
topology and health. GitHub stays the real source but does not need to be open. The older `Run` action
remains available for the original multi-window presentation.

For a longer scale-focused presentation, use `RunFleet`. It deploys the core four workloads, expands
to twelve, then retains all twelve healthy workloads while the isolated negative control fails:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Prepare
.\demo\Invoke-LiveDemo.ps1 -Action RunFleet
.\demo\Invoke-LiveDemo.ps1 -Action Cleanup
```

Cluster and workload inventory lives in [`demo/topology.json`](demo/topology.json). The controller
iterates that file, so adding a future cluster does not require PowerShell changes. Cluster creation,
Arc connection, registered extension installation, ACR role assignment, and monitoring installation
remain explicit offstage prerequisites; the demo controller never provisions Azure resources.