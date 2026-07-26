# Five-Minute ACR Auth + GitOps Monitoring Demo

## The story

One Git commit deploys four credential-free workloads through Microsoft Flux to two Arc-enabled
kind clusters. The ACR Auth Extension materializes short-lived registry credentials and mutates the
created Pods, allowing real pulls from three private ACRs. A second Git commit creates an identical
workload in an unmapped namespace: no Secret is created, no reference is injected, and Kubernetes
shows `ImagePullBackOff`. GitOps monitoring correlates Flux compliance and workload health for both
outcomes.

Do not install or update extensions during the five-minute presentation. The extensions, Azure Flux
configurations, namespaces, and positive pull Secrets are pre-warmed before the audience arrives.

## One-time setup

```powershell
Set-Location C:\Users\t-hbroughton\Documents\Milestone-2\acr-auth-gitops-demo
.\demo\Invoke-LiveDemo.ps1 -Action Initialize
```

This creates a separate Azure-managed Microsoft Flux configuration named
`acr-auth-negative-control`. It uses a 20-second health timeout, so the intentionally unhealthy
application turns clearly non-compliant without affecting the positive applications.

## Before the meeting

Run this 10-15 minutes before presenting:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Prepare
```

`Prepare` is idempotent. It commits a reset only if needed, reconciles exact Git SHAs, removes prior
demo Deployments and Pods through Flux pruning, preserves the four namespaces, waits for four unexpired
extension-owned pull Secrets, clears demo namespace Events, and verifies that the negative namespace
is not in either `acrMap`.

The complete noninteractive rehearsal was measured at **167.2 seconds**, leaving roughly two minutes
inside a five-minute slot for narration, GitHub, and frontend refreshes.

Open these before sharing the screen:

1. GitHub: <https://github.com/hunter-broughton/acr-auth-gitops-demo/commits/main>
2. The monitoring frontend filtered to `acr-auth-gitops-demo`.
3. One large PowerShell terminal in the repository root.

## Run the presentation

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Run
```

The script pauses between the positive and negative phases so you control the narration.
Its on-stage preflight uses GitHub and direct Kubernetes readiness only; a transient Azure Resource
Manager status/DNS issue cannot block the demo after `Prepare` has succeeded.

### 0:00-0:40 - Establish the proof boundary

- Show GitHub: four Deployments reference three private ACRs.
- Point out `imagePullPolicy: Always` and the absence of `imagePullSecrets`.
- State that ACR admin and anonymous pull are disabled.
- Explain that one commit fans out to two Arc clusters through Microsoft Flux.

### 0:40-2:10 - Positive commit

Press Enter/start the script. It pushes `Demo: deploy private ACR workloads`, forces both Flux
sources to reconcile, and waits for the exact commit on both clusters.

Narrate the output:

- Microsoft Flux applies the same Git revision to both clusters.
- Git-authored Deployment templates still show `<none>` for a pull Secret.
- Stored Pods show `azure-arc-acr-pull`, proving CREATE-time admission mutation.
- Four Ready workloads pulled from vision, speech, and NLP ACRs.
- AuthInjector logs and `acr_auth_webhook_admission_total{reason="inject"}` support the proof.
- Secret expiry plus `acr_auth_token_refresh_total` and `acr_auth_secret_age_seconds` prove that
  SecretProvisioner is maintaining short-lived material without displaying its payload.

Refresh the frontend. Show the two workload applications per cluster, their Git revision/compliance,
and healthy Deployment/ReplicaSet/Pod trees.

### 2:10-3:20 - Explain the integration

Use the healthy view to connect the two projects:

1. Git is desired state.
2. Microsoft Flux reconciles it.
3. ACR Auth supplies short-lived authentication without changing Git.
4. The kubelet performs a real private pull.
5. Monitoring reports compliance, workload health, lifecycle, and collector coverage.

Avoid opening Secret data. Showing Secret name, type, and expiry annotation is sufficient.

### 3:20-4:30 - Negative-control commit

Press Enter. The script pushes `Demo: add unmapped ACR negative control` and reconciles the separate
negative-control Flux application.

The proof should read:

- Namespace mapping: absent.
- Generated Secret: `<none>`.
- Injected Pod Secret: `<none>`.
- Pod state: `ErrImagePull` then `ImagePullBackOff`.
- AuthInjector decision: `namespace-not-mapped`.
- Kubernetes Warning Event: private pull authorization failure.

This is stronger than using a nonexistent tag: it uses the same known-good private image and changes
only namespace eligibility.

For the five-minute frontend view, use the immediate Pod Health row (`status.phase=Pending` and
waiting reason `ImagePullBackOff`). The monitoring backend polls Kubernetes Warning Events every
eight minutes by default, so the richer Event row is supporting evidence and may arrive after the
live slot. The controller always prints the Kubernetes Event immediately.

### 4:30-5:00 - Close in the frontend

Refresh the frontend and compare:

- `acr-auth-gitops-demo-workloads`: compliant GitOps, healthy workloads, authenticated pulls.
- `acr-auth-negative-control-negative-control`: intentionally non-compliant Kustomization, unhealthy
  Pod with `ImagePullBackOff`, no injected Secret.

Close with: the same desired-state pipeline produced both results; the namespace-to-ACR contract is
the only difference, and the monitoring extension explains that difference without exposing a
credential.

## Extended fleet showcase

Use this for a seven-to-ten-minute scale narrative, not the five-minute slot:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Prepare
.\demo\Invoke-LiveDemo.ps1 -Action RunFleet
```

`RunFleet` preserves the core positive phase, then pauses before a second Git commit expands four
Deployments to twelve. The four pre-warmed namespace Secrets serve all twelve workloads, so the
journey board can compare one Git SHA, Flux application, Secret reuse, admission injection, private
pull confirmation, and runtime readiness per cluster. A final `fleet-negative` stage keeps the
twelve mapped workloads healthy while adding the same isolated unmapped control.

The script emits six numbered steps for every phase:

1. Git desired state
2. Microsoft Flux reconciliation
3. SecretProvisioner readiness
4. AuthInjector admission
5. Kubelet and private ACR result
6. GitOps monitoring refresh

You can run only the expansion after a positive phase with:

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Scale
```

Do not use `Scale` for the timed five-minute path. Use `Run`, which remains the rehearsed four-workload
sequence.

### Adding another registered cluster

1. Connect and validate the cluster offstage; install Microsoft Flux, ACR Auth, and GitOps monitoring.
2. Add its namespace/workload Kustomizations under `clusters/<cluster-name>`.
3. Add one workload stage file to every directory under `demo/stages`.
4. Add the cluster, context, resource group, ARM ID, stage filename, and workload inventory to
  `demo/topology.json`.
5. Run `Preflight`, `Prepare`, and `RunFleet -NonInteractive` before presenting.

This deliberately does not automate Azure resource creation. A failed or partially onboarded cluster
cannot silently enter the live topology.

## After the meeting

```powershell
.\demo\Invoke-LiveDemo.ps1 -Action Cleanup
```

This returns Git and both clusters to the pre-warmed baseline. It does not remove extensions, Flux
configurations, namespaces, or the generated positive pull Secrets.

## Useful commands

```powershell
# Read-only current status
.\demo\Invoke-LiveDemo.ps1 -Action Status

# Run without the narration pause (rehearsal/CI)
.\demo\Invoke-LiveDemo.ps1 -Action Run -NonInteractive

# Recheck prerequisites only
.\demo\Invoke-LiveDemo.ps1 -Action Preflight

# Recheck only the on-stage GitHub/Kubernetes dependencies
.\demo\Invoke-LiveDemo.ps1 -Action LivePreflight
```

## Reliability choices

- **Prewarm outside the five minutes:** extension install, Flux install, ACR roles, namespaces, and
  positive Secrets are not live-demo dependencies.
- **Exact Git SHA waits:** the script does not mistake an old `Ready=True` for the new commit.
- **Full-file stage templates:** no fragile YAML line editing.
- **`imagePullPolicy: Always`:** Kubernetes contacts the registry whenever the container launches;
  cached layers do not remove the registry resolution step.
- **Known-good image for the negative control:** failure demonstrates missing authentication, not a
  typo or missing artifact.
- **Separate negative Flux application:** positive applications remain green while the control turns
  red within its 20-second health timeout.
- **Kubernetes state is the immediate proof:** Log Analytics and the frontend are supporting views,
  so ingestion latency cannot derail the live sequence.

## Research basis

- Microsoft documents `microsoft.flux` as the Arc cluster extension that installs Flux controllers,
  with one Git source and one or more dependent Kustomizations per Flux configuration:
  <https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-flux2>
- Microsoft describes Flux as pull-based desired-state reconciliation and supports dependencies and
  cluster-scale deployment:
  <https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-gitops-flux2>
- Kubernetes documents that mutating admission webhooks run before validation and can return a
  JSONPatch that changes the admitted Pod:
  <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes documents that `imagePullPolicy: Always` asks the runtime to contact the registry on
  every launch and that private images without credentials enter `ImagePullBackOff`, with retry delay
  increasing up to five minutes:
  <https://kubernetes.io/docs/concepts/containers/images/>
- Kubernetes documents `Waiting` container state and recommends Pod Events/status for diagnosis:
  <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>