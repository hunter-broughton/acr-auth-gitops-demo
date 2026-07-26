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