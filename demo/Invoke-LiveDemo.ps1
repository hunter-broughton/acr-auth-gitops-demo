[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Preflight', 'LivePreflight', 'Prepare', 'Run', 'RunFleet', 'Positive', 'Scale', 'Negative', 'Status', 'Cleanup')]
    [string]$Action = 'Status',
    [switch]$NonInteractive,
    [string]$Subscription = 'ClusterConfig-SubLib-002',
    [string]$WorkspaceId = 'acc96155-4b9b-4505-b0e4-c1016a73a24c',
    [int]$FluxTimeoutSeconds = 300,
    [int]$WorkloadTimeoutSeconds = 240,
    [int]$NegativeTimeoutSeconds = 150
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StageRoot = Join-Path $PSScriptRoot 'stages'
$OriginUrl = 'https://github.com/hunter-broughton/acr-auth-gitops-demo.git'
$MainFluxName = 'acr-auth-gitops-demo'
$NegativeFluxName = 'acr-auth-negative-control'
$NegativeNamespace = 'gitops-unmapped-control'
$NegativeDeployment = 'unmapped-model-trainer'
$NegativeOwnerName = 'acr-auth-negative-control-negative-control'
$Topology = Get-Content (Join-Path $PSScriptRoot 'topology.json') -Raw | ConvertFrom-Json
$Clusters = @($Topology.clusters)
$NegativeCluster = @($Clusters | Where-Object { $_.NegativeControl }) | Select-Object -First 1
if ($Clusters.Count -eq 0 -or -not $NegativeCluster) {
    throw 'demo/topology.json must define at least one cluster and one NegativeControl cluster.'
}
$ClusterArmIdA = $NegativeCluster.ClusterResourceId
$LiveFiles = @($Clusters | ForEach-Object { "clusters/$($_.RepoPath)/workloads/kustomization.yaml" })
$LiveFiles += "clusters/$($NegativeCluster.RepoPath)/negative-control/kustomization.yaml"

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Write-DemoStep {
    param([int]$Number, [string]$Name, [string]$Detail)
    Write-Host ("[{0}/6] {1,-18} {2}" -f $Number, $Name, $Detail) -ForegroundColor Yellow
}

function Get-ClusterWorkloads {
    param($Cluster, [switch]$IncludeFleet)
    @($Cluster.Workloads)
    if ($IncludeFleet) {
        @($Cluster.FleetWorkloads)
    }
}

function Assert-LastExitCode {
    param([string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds,
        [string]$Description,
        [int]$PollSeconds = 2
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
}

function Assert-Tooling {
    foreach ($command in @('az', 'git', 'kubectl')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command '$command' is not installed or not on PATH."
        }
    }
}

function Assert-CleanRepository {
    Push-Location $RepoRoot
    try {
        $status = @(git status --porcelain)
        Assert-LastExitCode 'git status'
        if ($status.Count -gt 0) {
            throw "The demo repository has uncommitted changes. Commit or discard them before running the controller.`n$($status -join "`n")"
        }
        if ((git branch --show-current) -ne 'main') {
            throw 'The demo controller must run from the main branch.'
        }
        if ((git remote get-url origin) -ne $OriginUrl) {
            throw "origin must be $OriginUrl."
        }
    }
    finally {
        Pop-Location
    }
}

function Get-FluxResourceName {
    param([string]$FluxName, [string]$KustomizationName)
    return "$FluxName-$KustomizationName"
}

function Request-FluxReconcile {
    param([string]$Context, [string]$FluxName)
    $requestedAt = (Get-Date).ToUniversalTime().ToString('o')
    kubectl --context $Context -n flux-system annotate "gitrepository/$FluxName" "reconcile.fluxcd.io/requestedAt=$requestedAt" --overwrite | Out-Null
    Assert-LastExitCode "request source reconciliation on $Context"
}

function Wait-FluxRevision {
    param(
        [string]$Context,
        [string]$FluxName,
        [string[]]$Kustomizations,
        [string]$GitSha,
        [switch]$AcceptAttemptedRevision
    )
    $targetRevision = "main@sha1:$GitSha"
    Wait-Until -TimeoutSeconds $FluxTimeoutSeconds -Description "$FluxName source revision $targetRevision on $Context" -Condition {
        $revision = kubectl --context $Context -n flux-system get "gitrepository/$FluxName" -o jsonpath='{.status.artifact.revision}' 2>$null
        return $revision -eq $targetRevision
    }
    foreach ($name in $Kustomizations) {
        $resourceName = Get-FluxResourceName -FluxName $FluxName -KustomizationName $name
        Wait-Until -TimeoutSeconds $FluxTimeoutSeconds -Description "$resourceName revision $targetRevision on $Context" -Condition {
            $resource = kubectl --context $Context -n flux-system get "kustomization/$resourceName" -o json 2>$null | ConvertFrom-Json
            if ($AcceptAttemptedRevision) {
                return $resource.status.lastAttemptedRevision -eq $targetRevision -or $resource.status.lastAppliedRevision -eq $targetRevision
            }
            return $resource.status.lastAppliedRevision -eq $targetRevision
        }
    }
}

function Sync-AllFlux {
    param([string]$GitSha)
    foreach ($cluster in $Clusters) {
        Request-FluxReconcile -Context $cluster.Context -FluxName $MainFluxName
    }
    Request-FluxReconcile -Context $NegativeCluster.Context -FluxName $NegativeFluxName

    foreach ($cluster in $Clusters) {
        Wait-FluxRevision -Context $cluster.Context -FluxName $MainFluxName -Kustomizations @('namespaces', 'workloads') -GitSha $GitSha
    }
    Wait-FluxRevision -Context $NegativeCluster.Context -FluxName $NegativeFluxName -Kustomizations @('negative-control') -GitSha $GitSha -AcceptAttemptedRevision
}

function Copy-Stage {
    param([ValidateSet('baseline', 'positive', 'negative', 'fleet', 'fleet-negative')][string]$Stage)
    $stageDirectory = Join-Path $StageRoot $Stage
    foreach ($cluster in $Clusters) {
        $destination = "clusters/$($cluster.RepoPath)/workloads/kustomization.yaml"
        Copy-Item (Join-Path $stageDirectory $cluster.StageFile) (Join-Path $RepoRoot $destination) -Force
    }
    $negativeDestination = "clusters/$($NegativeCluster.RepoPath)/negative-control/kustomization.yaml"
    Copy-Item (Join-Path $stageDirectory 'negative-control.yaml') (Join-Path $RepoRoot $negativeDestination) -Force

    $renderPaths = @($Clusters | ForEach-Object { "clusters/$($_.RepoPath)/workloads" })
    $renderPaths += "clusters/$($NegativeCluster.RepoPath)/negative-control"
    foreach ($path in $renderPaths) {
        kubectl kustomize (Join-Path $RepoRoot $path) | Out-Null
        Assert-LastExitCode "render $path"
    }
}

function Publish-Stage {
    param(
        [ValidateSet('baseline', 'positive', 'negative', 'fleet', 'fleet-negative')][string]$Stage,
        [string]$Message
    )
    Push-Location $RepoRoot
    try {
        Copy-Stage -Stage $Stage
        git add -- $LiveFiles
        Assert-LastExitCode 'git add demo stage'
        $staged = @(git diff --cached --name-only)
        if ($staged.Count -gt 0) {
            git commit -m $Message | Out-Host
            Assert-LastExitCode "commit $Stage stage"
            git push origin main | Out-Host
            Assert-LastExitCode "push $Stage stage"
        }
        else {
            Write-Host "Git already represents stage '$Stage'; no commit needed." -ForegroundColor DarkGray
        }
        $sha = git rev-parse HEAD
        Assert-LastExitCode 'resolve Git SHA'
    }
    finally {
        Pop-Location
    }
    Sync-AllFlux -GitSha $sha
    return $sha
}

function Get-AcrMap {
    param($Cluster)
    $extension = az k8s-extension show --subscription $Subscription --resource-group $Cluster.ResourceGroup --cluster-name $Cluster.Name --cluster-type connectedClusters --name acr-auth -o json | ConvertFrom-Json
    return @($extension.configurationSettings.psobject.Properties | Where-Object { $_.Name -like 'acrMap.*' })
}

function Test-ExtensionState {
    param($Cluster, [string]$Name, [string]$Type, [string]$Version)
    $extension = az k8s-extension show --subscription $Subscription --resource-group $Cluster.ResourceGroup --cluster-name $Cluster.Name --cluster-type connectedClusters --name $Name -o json | ConvertFrom-Json
    if ($extension.extensionType -ne $Type -or $extension.currentVersion -ne $Version -or $extension.provisioningState -ne 'Succeeded') {
        throw "$($Cluster.Name)/$Name is not $Type $Version Succeeded."
    }
}

function Invoke-LivePreflight {
    Write-Section 'Live preflight'
    Assert-Tooling
    Assert-CleanRepository

    foreach ($cluster in $Clusters) {
        $ready = kubectl --context $cluster.Context get --raw='/readyz' 2>$null
        if ($ready -ne 'ok') {
            throw "$($cluster.Context) API server is not ready."
        }

        foreach ($deployment in @('fluxconfig-agent', 'fluxconfig-controller', 'source-controller', 'kustomize-controller')) {
            $available = kubectl --context $cluster.Context -n flux-system get deployment $deployment -o jsonpath='{.status.availableReplicas}' 2>$null
            if ([int]$available -lt 1) {
                throw "$($cluster.Name) Microsoft Flux deployment $deployment is unavailable."
            }
        }

        $injectorReady = kubectl --context $cluster.Context -n azure-arc-acr-auth get deployment acr-auth-acr-auth-extension-authinjector -o jsonpath='{.status.readyReplicas}' 2>$null
        $provisionerReady = kubectl --context $cluster.Context -n azure-arc-acr-auth get deployment acr-auth-acr-auth-extension-secretprovisioner -o jsonpath='{.status.readyReplicas}' 2>$null
        if ([int]$injectorReady -lt 2 -or [int]$provisionerReady -lt 1) {
            throw "$($cluster.Name) ACR Auth components are not ready."
        }

        $sourceUrl = kubectl --context $cluster.Context -n flux-system get "gitrepository/$MainFluxName" -o jsonpath='{.spec.url}' 2>$null
        if ($sourceUrl -ne $OriginUrl) {
            throw "$($cluster.Name) main Flux source is not the GitHub repository."
        }

        foreach ($workload in $cluster.Workloads) {
            Wait-SecretReady -Context $cluster.Context -Namespace $workload.Namespace
        }
    }

    $negativeSource = kubectl --context $NegativeCluster.Context -n flux-system get "gitrepository/$NegativeFluxName" -o jsonpath='{.spec.url}' 2>$null
    if ($negativeSource -ne $OriginUrl) {
        throw 'The negative-control Flux source is not initialized from GitHub.'
    }
    if (kubectl --context $NegativeCluster.Context -n $NegativeNamespace get secret azure-arc-acr-pull --ignore-not-found -o name) {
        throw "$NegativeNamespace unexpectedly contains azure-arc-acr-pull."
    }

    Write-Host 'Live preflight passed: GitHub, both clusters, Microsoft Flux, ACR Auth, and positive Secrets are ready.' -ForegroundColor Green
}

function Invoke-Preflight {
    Write-Section 'Preflight'
    Assert-Tooling
    Assert-CleanRepository

    $yamlFiles = Get-ChildItem $RepoRoot -Recurse -File -Include '*.yaml', '*.yml' | Where-Object { $_.FullName -notlike '*\demo\stages\*' }
    $credentialReferences = @($yamlFiles | Select-String -Pattern 'imagePullSecrets|dockerconfigjson|azure-arc-acr-pull')
    if ($credentialReferences.Count -gt 0) {
        throw "Credential reference found in Git-authored manifests:`n$($credentialReferences -join "`n")"
    }

    foreach ($cluster in $Clusters) {
        Test-ExtensionState -Cluster $cluster -Name flux -Type microsoft.flux -Version '1.24.0'
        Test-ExtensionState -Cluster $cluster -Name acr-auth -Type microsoft.test.authinjector -Version '0.1.18'
        $flux = az k8s-configuration flux show --subscription $Subscription --resource-group $cluster.ResourceGroup --cluster-name $cluster.Name --cluster-type connectedClusters --name $MainFluxName -o json | ConvertFrom-Json
        if ($flux.provisioningState -ne 'Succeeded' -or $flux.gitRepository.url -ne $OriginUrl) {
            throw "$($cluster.Name) main Flux configuration is not healthy or does not use GitHub."
        }
        $maps = Get-AcrMap -Cluster $cluster
        if ($maps.Name -contains "acrMap.$NegativeNamespace") {
            throw "$NegativeNamespace must remain absent from acrMap."
        }
    }

    $negativeFlux = az k8s-configuration flux show --subscription $Subscription --resource-group $NegativeCluster.ResourceGroup --cluster-name $NegativeCluster.Name --cluster-type connectedClusters --name $NegativeFluxName -o json | ConvertFrom-Json
    if ($negativeFlux.provisioningState -ne 'Succeeded' -or $negativeFlux.gitRepository.url -ne $OriginUrl) {
        throw 'The negative-control Microsoft Flux configuration is not initialized.'
    }

    foreach ($registry in @('acrvisiontrainkgw7x', 'acrspeechtrainkgw7x', 'acrnlptrainkgw7x')) {
        $acr = az acr show --subscription $Subscription --name $registry -o json | ConvertFrom-Json
        if ($acr.adminUserEnabled -or $acr.anonymousPullEnabled) {
            throw "$registry must have admin and anonymous pull disabled."
        }
    }
    Write-Host 'Preflight passed: GitHub, Microsoft Flux, ACR Auth, private registries, and maps are ready.' -ForegroundColor Green
}

function Wait-DeploymentAbsent {
    param([string]$Context, [string]$Namespace, [string]$Deployment)
    Wait-Until -TimeoutSeconds $WorkloadTimeoutSeconds -Description "$Namespace/$Deployment removal" -Condition {
        $name = kubectl --context $Context -n $Namespace get deployment $Deployment --ignore-not-found -o name 2>$null
        return [string]::IsNullOrWhiteSpace($name)
    }
}

function Wait-PodsAbsent {
    param([string]$Context, [string]$Namespace, [string]$Deployment)
    Wait-Until -TimeoutSeconds $WorkloadTimeoutSeconds -Description "$Namespace/$Deployment Pod removal" -Condition {
        $pods = kubectl --context $Context -n $Namespace get pod -l "app.kubernetes.io/name=$Deployment" -o name 2>$null
        return [string]::IsNullOrWhiteSpace($pods)
    }
}

function Wait-SecretReady {
    param([string]$Context, [string]$Namespace)
    Wait-Until -TimeoutSeconds $WorkloadTimeoutSeconds -Description "$Namespace/azure-arc-acr-pull" -Condition {
        $type = kubectl --context $Context -n $Namespace get secret azure-arc-acr-pull -o jsonpath='{.type}' 2>$null
        $expiry = kubectl --context $Context -n $Namespace get secret azure-arc-acr-pull -o jsonpath='{.metadata.annotations.acr-auth\.azure\.com/expires-at}' 2>$null
        if ($type -ne 'kubernetes.io/dockerconfigjson' -or [string]::IsNullOrWhiteSpace($expiry)) {
            return $false
        }
        return ([datetime]$expiry).ToUniversalTime() -gt (Get-Date).ToUniversalTime()
    }
}

function Invoke-Prepare {
    param([switch]$FastPreflight)
    if ($FastPreflight) {
        Invoke-LivePreflight
    }
    else {
        Invoke-Preflight
    }
    Write-Section 'Reset Git to namespace and Secret prewarm'
    $sha = Publish-Stage -Stage baseline -Message 'Demo reset: prewarm namespaces'

    foreach ($cluster in $Clusters) {
        foreach ($workload in @(Get-ClusterWorkloads -Cluster $cluster -IncludeFleet)) {
            Wait-DeploymentAbsent -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            Wait-PodsAbsent -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            Wait-SecretReady -Context $cluster.Context -Namespace $workload.Namespace
            kubectl --context $cluster.Context -n $workload.Namespace delete events --all --ignore-not-found | Out-Null
        }
    }
    Wait-DeploymentAbsent -Context $NegativeCluster.Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    Wait-PodsAbsent -Context $NegativeCluster.Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    kubectl --context $NegativeCluster.Context -n $NegativeNamespace delete events --all --ignore-not-found | Out-Null

    Write-Host "Prepared at Git commit $($sha.Substring(0, 7)). Positive namespaces and extension-owned Secrets are warm; no demo Deployments exist." -ForegroundColor Green
}

function Wait-DeploymentReady {
    param([string]$Context, [string]$Namespace, [string]$Deployment)
    kubectl --context $Context -n $Namespace rollout status "deployment/$Deployment" --timeout="${WorkloadTimeoutSeconds}s"
    Assert-LastExitCode "$Namespace/$Deployment rollout"
}

function Get-PodName {
    param([string]$Context, [string]$Namespace, [string]$Deployment)
    $pod = kubectl --context $Context -n $Namespace get pod -l "app.kubernetes.io/name=$Deployment" -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ([string]::IsNullOrWhiteSpace($pod)) {
        throw "No Pod found for $Namespace/$Deployment."
    }
    return $pod
}

function Show-PositiveProof {
    param([switch]$IncludeFleet)
    $rows = @()
    foreach ($cluster in $Clusters) {
        foreach ($workload in @(Get-ClusterWorkloads -Cluster $cluster -IncludeFleet:$IncludeFleet)) {
            $pod = Get-PodName -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            $deploymentSecret = kubectl --context $cluster.Context -n $workload.Namespace get deployment $workload.Deployment -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}'
            $podSecret = kubectl --context $cluster.Context -n $workload.Namespace get pod $pod -o jsonpath='{.spec.imagePullSecrets[*].name}'
            $ready = kubectl --context $cluster.Context -n $workload.Namespace get pod $pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
            $image = kubectl --context $cluster.Context -n $workload.Namespace get pod $pod -o jsonpath='{.spec.containers[0].image}'
            $secretExpiry = kubectl --context $cluster.Context -n $workload.Namespace get secret azure-arc-acr-pull -o jsonpath='{.metadata.annotations.acr-auth\.azure\.com/expires-at}'
            $pulled = @(kubectl --context $cluster.Context -n $workload.Namespace get events --field-selector "involvedObject.name=$pod" -o json | ConvertFrom-Json | Select-Object -ExpandProperty items | Where-Object { $_.reason -eq 'Pulled' }).Count
            $rows += [pscustomobject]@{
                Cluster = $cluster.Name
                Namespace = $workload.Namespace
                Deployment = $workload.Deployment
                GitSecret = if ($deploymentSecret) { $deploymentSecret } else { '<none>' }
                PodSecret = $podSecret
                Ready = $ready
                Pulled = $pulled
                SecretExpiry = $secretExpiry
                Image = $image
            }
        }
    }
    $rows | Format-Table Cluster, Namespace, Deployment, GitSecret, PodSecret, Ready, Pulled, SecretExpiry, Image -AutoSize -Wrap
}

function Show-JourneyBoard {
    param([string]$GitSha, [switch]$IncludeFleet)
    $rows = @()
    foreach ($cluster in $Clusters) {
        $workloads = @(Get-ClusterWorkloads -Cluster $cluster -IncludeFleet:$IncludeFleet)
        $injected, $pulled, $ready = 0, 0, 0
        foreach ($workload in $workloads) {
            $pod = Get-PodName -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            if (kubectl --context $cluster.Context -n $workload.Namespace get pod $pod -o jsonpath='{.spec.imagePullSecrets[*].name}' | Select-String -SimpleMatch 'azure-arc-acr-pull') {
                $injected++
            }
            if ((kubectl --context $cluster.Context -n $workload.Namespace get pod $pod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') -eq 'True') {
                $ready++
            }
            $pullEvents = @(kubectl --context $cluster.Context -n $workload.Namespace get events --field-selector "involvedObject.name=$pod,reason=Pulled" -o name 2>$null)
            if ($pullEvents.Count -gt 0) {
                $pulled++
            }
        }
        $rows += [pscustomobject]@{
            Cluster = $cluster.Name
            Git = $GitSha.Substring(0, 7)
            Flux = 'Applied'
            AcrSecrets = "$(@($workloads.Namespace | Sort-Object -Unique).Count) warm"
            Admission = "$injected/$($workloads.Count) injected"
            PrivatePull = "$pulled/$($workloads.Count) confirmed"
            Runtime = "$ready/$($workloads.Count) ready"
        }
    }
    Write-Host "`nCluster journey board:" -ForegroundColor Yellow
    $rows | Format-Table -AutoSize
    Write-Host 'Next: refresh the cluster view for reconciliation, inventory, runtime, and collector activity.' -ForegroundColor DarkCyan
}

function Show-AuthLogs {
    param([datetime]$Since, [string]$Pattern)
    $sinceTime = $Since.ToUniversalTime().AddSeconds(-30).ToString('o')
    foreach ($cluster in $Clusters) {
        $pods = kubectl --context $cluster.Context -n azure-arc-acr-auth get pods -l app.kubernetes.io/component=auth-injector -o jsonpath='{.items[*].metadata.name}'
        foreach ($pod in ($pods -split ' ')) {
            if (-not [string]::IsNullOrWhiteSpace($pod)) {
                kubectl --context $cluster.Context -n azure-arc-acr-auth logs $pod --since-time=$sinceTime 2>$null | Select-String -Pattern $Pattern -CaseSensitive:$false
            }
        }
    }
}

function Get-MetricSample {
    param([string]$MetricPattern)
    $samples = @()
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $raw = kubectl --context $NegativeCluster.Context get --raw '/api/v1/namespaces/azure-arc-acr-auth/services/http:acr-auth-acr-auth-extension-authinjector:metrics/proxy/metrics' 2>$null
        $samples += @($raw -split "`n" | Where-Object { $_ -match $MetricPattern })
        Start-Sleep -Milliseconds 150
    }
    return @($samples | Sort-Object -Unique)
}

function Get-ProvisionerMetrics {
    $raw = kubectl --context $NegativeCluster.Context get --raw '/api/v1/namespaces/azure-arc-acr-auth/services/http:acr-auth-acr-auth-extension-secretprovisioner-metrics:metrics/proxy/metrics' 2>$null
    return @($raw -split "`n" | Where-Object {
        $_ -match '^acr_auth_token_refresh_total\{result="success"\}' -or
        $_ -match '^acr_auth_secret_age_seconds\{namespace="gitops-(vision|speech)-a"\}'
    })
}

function Invoke-Positive {
    Write-Section 'Git commit: deploy four private workloads'
    $started = (Get-Date).ToUniversalTime()
    Write-DemoStep -Number 1 -Name 'Git desired state' -Detail 'Publishing four credential-free Deployments.'
    $sha = Publish-Stage -Stage positive -Message 'Demo: deploy private ACR workloads'
    Write-DemoStep -Number 2 -Name 'Microsoft Flux' -Detail "Both clusters applied $($sha.Substring(0, 7))."
    Write-DemoStep -Number 3 -Name 'SecretProvisioner' -Detail 'Short-lived extension-owned pull Secrets were pre-warmed.'
    foreach ($cluster in $Clusters) {
        foreach ($workload in $cluster.Workloads) {
            Wait-DeploymentReady -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
        }
    }
    Write-DemoStep -Number 4 -Name 'AuthInjector' -Detail 'Stored Pods received azure-arc-acr-pull during admission.'
    Show-PositiveProof
    Write-DemoStep -Number 5 -Name 'Kubelet + ACR' -Detail 'Private pulls completed and all four Pods are Ready.'
    Show-JourneyBoard -GitSha $sha
    Write-Host "`nAuthInjector evidence:" -ForegroundColor Yellow
    Show-AuthLogs -Since $started -Pattern 'injected azure-arc-acr-pull'
    Write-Host "`nWebhook metric samples:" -ForegroundColor Yellow
    Get-MetricSample -MetricPattern '^acr_auth_webhook_admission_total\{reason="inject"\}' | ForEach-Object { Write-Host $_ }
    Write-Host "`nSecretProvisioner metrics:" -ForegroundColor Yellow
    Get-ProvisionerMetrics | ForEach-Object { Write-Host $_ }
    Write-DemoStep -Number 6 -Name 'GitOps monitor' -Detail 'Refresh the cluster view to follow reconciliation and runtime activity.'
}

function Invoke-Scale {
    Write-Section 'Git commit: expand to twelve private workloads'
    $started = (Get-Date).ToUniversalTime()
    Write-DemoStep -Number 1 -Name 'Git desired state' -Detail 'Adding batch and canary workloads without new credentials.'
    $sha = Publish-Stage -Stage fleet -Message 'Demo: expand private ACR workload fleet'
    Write-DemoStep -Number 2 -Name 'Microsoft Flux' -Detail "Both clusters applied $($sha.Substring(0, 7))."
    Write-DemoStep -Number 3 -Name 'SecretProvisioner' -Detail 'The same four namespace-scoped Secrets serve twelve workloads.'
    foreach ($cluster in $Clusters) {
        foreach ($workload in @(Get-ClusterWorkloads -Cluster $cluster -IncludeFleet)) {
            Wait-DeploymentReady -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
        }
    }
    Write-DemoStep -Number 4 -Name 'AuthInjector' -Detail 'Every newly created Pod received the extension-owned reference.'
    Show-PositiveProof -IncludeFleet
    Write-DemoStep -Number 5 -Name 'Kubelet + ACR' -Detail 'Twelve always-pull workloads are Ready across three private registries.'
    Show-JourneyBoard -GitSha $sha -IncludeFleet
    Write-Host "`nFleet AuthInjector evidence:" -ForegroundColor Yellow
    Show-AuthLogs -Since $started -Pattern 'injected azure-arc-acr-pull'
    Write-DemoStep -Number 6 -Name 'GitOps monitor' -Detail 'Refresh the activity rail and watch the resource graph expand.'
}

function Wait-NegativePod {
    Wait-Until -TimeoutSeconds $NegativeTimeoutSeconds -Description "$NegativeNamespace/$NegativeDeployment Pod creation" -Condition {
        $name = kubectl --context $NegativeCluster.Context -n $NegativeNamespace get pod -l "app.kubernetes.io/name=$NegativeDeployment" -o jsonpath='{.items[0].metadata.name}' 2>$null
        return -not [string]::IsNullOrWhiteSpace($name)
    }
    $pod = Get-PodName -Context $NegativeCluster.Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    Wait-Until -TimeoutSeconds $NegativeTimeoutSeconds -Description "$pod ImagePullBackOff" -Condition {
        $reason = kubectl --context $NegativeCluster.Context -n $NegativeNamespace get pod $pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>$null
        return $reason -in @('ErrImagePull', 'ImagePullBackOff')
    }
    return $pod
}

function Show-NegativeProof {
    param([string]$Pod)
    $secret = kubectl --context $NegativeCluster.Context -n $NegativeNamespace get secret azure-arc-acr-pull --ignore-not-found -o name
    $podSecret = kubectl --context $NegativeCluster.Context -n $NegativeNamespace get pod $Pod -o jsonpath='{.spec.imagePullSecrets[*].name}'
    $waitingReason = kubectl --context $NegativeCluster.Context -n $NegativeNamespace get pod $Pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}'
    $warning = @(kubectl --context $NegativeCluster.Context -n $NegativeNamespace get events --field-selector "involvedObject.name=$Pod,type=Warning" -o json | ConvertFrom-Json | Select-Object -ExpandProperty items | Sort-Object { $_.lastTimestamp } -Descending | Select-Object -First 1)
    [pscustomobject]@{
        NamespaceMapped = $false
        GeneratedSecret = if ($secret) { $secret } else { '<none>' }
        InjectedPodSecret = if ($podSecret) { $podSecret } else { '<none>' }
        Pod = $Pod
        WaitingReason = $waitingReason
        EventReason = $warning.reason
        EventMessage = $warning.message
    } | Format-List
}

function Show-MonitoringQuery {
    param([datetime]$Since)
    $timestamp = $Since.ToUniversalTime().ToString('o')
    $query = @"
ResourceSyncNotifications_CL
| where TimeGenerated >= datetime($timestamp)
| where tolower(ClusterResourceId) == tolower('$ClusterArmIdA')
| where OwnerName in ('acr-auth-gitops-demo-workloads', '$NegativeOwnerName')
| extend F=todynamic(Fields)
| summarize Latest=max(TimeGenerated), Rows=count(), Objects=dcount(Uid),
            Kinds=make_set(Kind),
            PodPhases=make_set(tostring(F['status.phase'])),
            WaitingReasons=make_set(tostring(F['status.containerStatuses[*].state.waiting.reason']))
  by OwnerName, Category
| order by OwnerName asc, Category asc
"@
    try {
        $rows = az monitor log-analytics query --subscription $Subscription --workspace $WorkspaceId --analytics-query $query --timespan P1D -o json | ConvertFrom-Json
        if ($rows.Count -gt 0) {
            $rows | Select-Object OwnerName, Category, Objects, Rows, Kinds, PodPhases, WaitingReasons, Latest | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Host 'Monitoring rows are still ingesting. Refresh the frontend in a few seconds.' -ForegroundColor DarkYellow
        }
    }
    catch {
        Write-Host "Monitoring query is not presentation-blocking: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Invoke-Negative {
    param([ValidateSet('negative', 'fleet-negative')][string]$Stage = 'negative')
    Write-Section 'Git commit: add unmapped namespace negative control'
    $started = (Get-Date).ToUniversalTime()
    Write-DemoStep -Number 1 -Name 'Git desired state' -Detail 'Adding the known-good image in an unmapped namespace.'
    $sha = Publish-Stage -Stage $Stage -Message 'Demo: add unmapped ACR negative control'
    Write-DemoStep -Number 2 -Name 'Microsoft Flux' -Detail "The isolated control attempted $($sha.Substring(0, 7))."
    $pod = Wait-NegativePod
    Write-DemoStep -Number 3 -Name 'SecretProvisioner' -Detail 'No namespace mapping means no generated pull Secret.'
    Write-DemoStep -Number 4 -Name 'AuthInjector' -Detail 'The Pod was deliberately left without an injected reference.'
    Write-Host "Negative control applied at $($sha.Substring(0, 7))." -ForegroundColor Green
    Show-NegativeProof -Pod $pod
    Write-DemoStep -Number 5 -Name 'Kubelet + ACR' -Detail 'The real private registry rejected the unauthenticated pull.'
    Write-Host 'AuthInjector decision:' -ForegroundColor Yellow
    Show-AuthLogs -Since $started -Pattern "namespace-not-mapped|$NegativeNamespace"
    Write-Host 'Webhook metric samples:' -ForegroundColor Yellow
    Get-MetricSample -MetricPattern '^acr_auth_webhook_admission_total\{reason="namespace-not-mapped"\}' | ForEach-Object { Write-Host $_ }
    Write-Host 'Monitoring snapshot:' -ForegroundColor Yellow
    Show-MonitoringQuery -Since $started
    Write-DemoStep -Number 6 -Name 'GitOps monitor' -Detail 'Compare blocked runtime health with the healthy mapped workloads.'
}

function Show-Status {
    Write-Section 'Git and Flux status'
    Push-Location $RepoRoot
    try {
        [pscustomobject]@{
            Repository = (git remote get-url origin)
            Branch = (git branch --show-current)
            Commit = (git rev-parse --short HEAD)
            Clean = (@(git status --porcelain).Count -eq 0)
        } | Format-List
    }
    finally {
        Pop-Location
    }
    foreach ($cluster in $Clusters) {
        Write-Host "`n$($cluster.Name)" -ForegroundColor Yellow
        kubectl --context $cluster.Context -n flux-system get "gitrepository/$MainFluxName" "kustomization/$MainFluxName-namespaces" "kustomization/$MainFluxName-workloads" -o custom-columns='KIND:.kind,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.lastAppliedRevision,ARTIFACT:.status.artifact.revision'
        foreach ($workload in $cluster.Workloads) {
            kubectl --context $cluster.Context -n $workload.Namespace get deployment $workload.Deployment --ignore-not-found -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[0].image'
        }
    }
    kubectl --context $NegativeCluster.Context -n $NegativeNamespace get deployment,pod --ignore-not-found
}

function Invoke-PreflightBase {
    Assert-Tooling
    Assert-CleanRepository
}

function Initialize-Demo {
    Invoke-PreflightBase
    Write-Section 'Initialize isolated negative-control Flux application'
    $existing = az k8s-configuration flux list --subscription $Subscription --resource-group $NegativeCluster.ResourceGroup --cluster-name $NegativeCluster.Name --cluster-type connectedClusters -o json | ConvertFrom-Json | Where-Object { $_.name -eq $NegativeFluxName }
    if (-not $existing) {
        az k8s-configuration flux create --subscription $Subscription --resource-group $NegativeCluster.ResourceGroup --cluster-name $NegativeCluster.Name --cluster-type connectedClusters --name $NegativeFluxName --scope cluster --namespace flux-system --kind git --url $OriginUrl --branch main --kustomization name=negative-control path="./clusters/$($NegativeCluster.RepoPath)/negative-control" prune=true sync_interval=30s retry_interval=15s timeout=20s -o table
        Assert-LastExitCode 'create negative-control Flux configuration'
    }
    else {
        az k8s-configuration flux update --subscription $Subscription --resource-group $NegativeCluster.ResourceGroup --cluster-name $NegativeCluster.Name --cluster-type connectedClusters --name $NegativeFluxName --kind git --url $OriginUrl --branch main --kustomization name=negative-control path="./clusters/$($NegativeCluster.RepoPath)/negative-control" prune=true sync_interval=30s retry_interval=15s timeout=20s -o none
        Assert-LastExitCode 'update negative-control Flux configuration'
        Write-Host 'Negative-control Flux configuration already exists; parameters refreshed.' -ForegroundColor DarkGray
    }
    Invoke-Preflight
}

function Assert-DemoBaseline {
    foreach ($cluster in $Clusters) {
        foreach ($workload in @(Get-ClusterWorkloads -Cluster $cluster -IncludeFleet)) {
            if (kubectl --context $cluster.Context -n $workload.Namespace get deployment $workload.Deployment --ignore-not-found -o name) {
                throw 'The demo is not at baseline. Run -Action Prepare before the presentation.'
            }
        }
    }
}

Set-Location $RepoRoot

switch ($Action) {
    'Initialize' { Initialize-Demo }
    'Preflight' { Invoke-Preflight }
    'LivePreflight' { Invoke-LivePreflight }
    'Prepare' { Invoke-Prepare }
    'Cleanup' { Invoke-Prepare -FastPreflight }
    'Positive' {
        Invoke-LivePreflight
        Invoke-Positive
    }
    'Scale' {
        Invoke-LivePreflight
        Invoke-Scale
    }
    'Negative' {
        Invoke-LivePreflight
        Invoke-Negative
    }
    'Run' {
        Invoke-LivePreflight
        Assert-DemoBaseline
        $demoStarted = (Get-Date).ToUniversalTime()
        Invoke-Positive
        if (-not $NonInteractive) {
            Read-Host 'Positive proof complete. Refresh the frontend, then press Enter for the unmapped negative control'
        }
        Invoke-Negative
        Write-Host "`nDemo complete. Refresh the frontend and compare the healthy workload application with $NegativeOwnerName." -ForegroundColor Green
        Show-MonitoringQuery -Since $demoStarted
    }
    'RunFleet' {
        Invoke-LivePreflight
        Assert-DemoBaseline
        $demoStarted = (Get-Date).ToUniversalTime()
        Invoke-Positive
        if (-not $NonInteractive) {
            Read-Host 'Core proof complete. Refresh the cluster activity view, then press Enter to expand the fleet'
        }
        Invoke-Scale
        if (-not $NonInteractive) {
            Read-Host 'Fleet proof complete. Refresh the resource counts, then press Enter for the unmapped control'
        }
        Invoke-Negative -Stage fleet-negative
        Write-Host "`nFleet demo complete: twelve authenticated workloads remain healthy while the isolated control is blocked." -ForegroundColor Green
        Show-MonitoringQuery -Since $demoStarted
    }
    'Status' { Show-Status }
}