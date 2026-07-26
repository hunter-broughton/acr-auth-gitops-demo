# ACR Auth GitOps Demo

This repository drives two Arc-enabled kind clusters through Microsoft Flux. Each workload uses a
private ACR image with `imagePullPolicy: Always` and deliberately omits `imagePullSecrets`.

| Cluster | Namespace | Registry | Workload |
| --- | --- | --- | --- |
| `hbroughton-acr-test-kind` | `gitops-vision-a` | `acrvisiontrainkgw7x.azurecr.io` | `vision-model-trainer` |
| `hbroughton-acr-test-kind` | `gitops-speech-a` | `acrspeechtrainkgw7x.azurecr.io` | `speech-model-trainer` |
| `acr-auth-demo` | `gitops-nlp-b` | `acrnlptrainkgw7x.azurecr.io` | `nlp-model-trainer` |
| `acr-auth-demo` | `gitops-vision-b` | `acrvisiontrainkgw7x.azurecr.io` | `vision-model-trainer` |

The namespace kustomizations reconcile first. Workload kustomizations depend on them, allowing the
ACR Auth SecretProvisioner to create `azure-arc-acr-pull` before the Deployments are enabled in the
second demo commit.