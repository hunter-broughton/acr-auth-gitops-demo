[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Preflight', 'Prepare', 'Run', 'Positive', 'Negative', 'Status', 'Cleanup')]
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
$ClusterArmIdA = '/subscriptions/0e750457-5252-493e-95a3-e40e6a460bf0/resourceGroups/hbroughton-acr-auth-test/providers/Microsoft.Kubernetes/connectedClusters/hbroughton-acr-test-kind'

$Clusters = @(
    [pscustomobject]@{
        Name = 'hbroughton-acr-test-kind'
        ResourceGroup = 'hbroughton-acr-auth-test'
        Context = 'kind-hbroughton-acr-test-kind'
        RepoPath = 'hbroughton-acr-test-kind'
        Workloads = @(
            [pscustomobject]@{ Namespace = 'gitops-vision-a'; Deployment = 'vision-model-trainer'; Registry = 'acrvisiontrainkgw7x.azurecr.io' },
            [pscustomobject]@{ Namespace = 'gitops-speech-a'; Deployment = 'speech-model-trainer'; Registry = 'acrspeechtrainkgw7x.azurecr.io' }
        )
    },
    [pscustomobject]@{
        Name = 'acr-auth-demo'
        ResourceGroup = 'acr-auth-demo'
        Context = 'kind-acr-auth-demo'
        RepoPath = 'acr-auth-demo'
        Workloads = @(
            [pscustomobject]@{ Namespace = 'gitops-nlp-b'; Deployment = 'nlp-model-trainer'; Registry = 'acrnlptrainkgw7x.azurecr.io' },
            [pscustomobject]@{ Namespace = 'gitops-vision-b'; Deployment = 'vision-model-trainer'; Registry = 'acrvisiontrainkgw7x.azurecr.io' }
        )
    }
)

$LiveFiles = @(
    'clusters/hbroughton-acr-test-kind/workloads/kustomization.yaml',
    'clusters/acr-auth-demo/workloads/kustomization.yaml',
    'clusters/hbroughton-acr-test-kind/negative-control/kustomization.yaml'
)

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
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
    Request-FluxReconcile -Context $Clusters[0].Context -FluxName $NegativeFluxName

    foreach ($cluster in $Clusters) {
        Wait-FluxRevision -Context $cluster.Context -FluxName $MainFluxName -Kustomizations @('namespaces', 'workloads') -GitSha $GitSha
    }
    Wait-FluxRevision -Context $Clusters[0].Context -FluxName $NegativeFluxName -Kustomizations @('negative-control') -GitSha $GitSha -AcceptAttemptedRevision
}

function Copy-Stage {
    param([ValidateSet('baseline', 'positive', 'negative')][string]$Stage)
    $stageDirectory = Join-Path $StageRoot $Stage
    Copy-Item (Join-Path $stageDirectory 'cluster-a-workloads.yaml') (Join-Path $RepoRoot $LiveFiles[0]) -Force
    Copy-Item (Join-Path $stageDirectory 'cluster-b-workloads.yaml') (Join-Path $RepoRoot $LiveFiles[1]) -Force
    Copy-Item (Join-Path $stageDirectory 'negative-control.yaml') (Join-Path $RepoRoot $LiveFiles[2]) -Force

    foreach ($path in @(
        'clusters/hbroughton-acr-test-kind/workloads',
        'clusters/acr-auth-demo/workloads',
        'clusters/hbroughton-acr-test-kind/negative-control'
    )) {
        kubectl kustomize (Join-Path $RepoRoot $path) | Out-Null
        Assert-LastExitCode "render $path"
    }
}

function Publish-Stage {
    param(
        [ValidateSet('baseline', 'positive', 'negative')][string]$Stage,
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

    $negativeFlux = az k8s-configuration flux show --subscription $Subscription --resource-group $Clusters[0].ResourceGroup --cluster-name $Clusters[0].Name --cluster-type connectedClusters --name $NegativeFluxName -o json | ConvertFrom-Json
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
    Invoke-Preflight
    Write-Section 'Reset Git to namespace and Secret prewarm'
    $sha = Publish-Stage -Stage baseline -Message 'Demo reset: prewarm namespaces'

    foreach ($cluster in $Clusters) {
        foreach ($workload in $cluster.Workloads) {
            Wait-DeploymentAbsent -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            Wait-PodsAbsent -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
            Wait-SecretReady -Context $cluster.Context -Namespace $workload.Namespace
            kubectl --context $cluster.Context -n $workload.Namespace delete events --all --ignore-not-found | Out-Null
        }
    }
    Wait-DeploymentAbsent -Context $Clusters[0].Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    Wait-PodsAbsent -Context $Clusters[0].Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    kubectl --context $Clusters[0].Context -n $NegativeNamespace delete events --all --ignore-not-found | Out-Null

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
    $rows = @()
    foreach ($cluster in $Clusters) {
        foreach ($workload in $cluster.Workloads) {
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
        $raw = kubectl --context $Clusters[0].Context get --raw '/api/v1/namespaces/azure-arc-acr-auth/services/http:acr-auth-acr-auth-extension-authinjector:metrics/proxy/metrics' 2>$null
        $samples += @($raw -split "`n" | Where-Object { $_ -match $MetricPattern })
        Start-Sleep -Milliseconds 150
    }
    return @($samples | Sort-Object -Unique)
}

function Get-ProvisionerMetrics {
    $raw = kubectl --context $Clusters[0].Context get --raw '/api/v1/namespaces/azure-arc-acr-auth/services/http:acr-auth-acr-auth-extension-secretprovisioner-metrics:metrics/proxy/metrics' 2>$null
    return @($raw -split "`n" | Where-Object {
        $_ -match '^acr_auth_token_refresh_total\{result="success"\}' -or
        $_ -match '^acr_auth_secret_age_seconds\{namespace="gitops-(vision|speech)-a"\}'
    })
}

function Invoke-Positive {
    Write-Section 'Git commit: deploy four private workloads'
    $started = (Get-Date).ToUniversalTime()
    $sha = Publish-Stage -Stage positive -Message 'Demo: deploy private ACR workloads'
    foreach ($cluster in $Clusters) {
        foreach ($workload in $cluster.Workloads) {
            Wait-DeploymentReady -Context $cluster.Context -Namespace $workload.Namespace -Deployment $workload.Deployment
        }
    }
    Write-Host "Both clusters applied $($sha.Substring(0, 7))." -ForegroundColor Green
    Show-PositiveProof
    Write-Host "`nAuthInjector evidence:" -ForegroundColor Yellow
    Show-AuthLogs -Since $started -Pattern 'injected azure-arc-acr-pull'
    Write-Host "`nWebhook metric samples:" -ForegroundColor Yellow
    Get-MetricSample -MetricPattern '^acr_auth_webhook_admission_total\{reason="inject"\}' | ForEach-Object { Write-Host $_ }
    Write-Host "`nSecretProvisioner metrics:" -ForegroundColor Yellow
    Get-ProvisionerMetrics | ForEach-Object { Write-Host $_ }
}

function Wait-NegativePod {
    Wait-Until -TimeoutSeconds $NegativeTimeoutSeconds -Description "$NegativeNamespace/$NegativeDeployment Pod creation" -Condition {
        $name = kubectl --context $Clusters[0].Context -n $NegativeNamespace get pod -l "app.kubernetes.io/name=$NegativeDeployment" -o jsonpath='{.items[0].metadata.name}' 2>$null
        return -not [string]::IsNullOrWhiteSpace($name)
    }
    $pod = Get-PodName -Context $Clusters[0].Context -Namespace $NegativeNamespace -Deployment $NegativeDeployment
    Wait-Until -TimeoutSeconds $NegativeTimeoutSeconds -Description "$pod ImagePullBackOff" -Condition {
        $reason = kubectl --context $Clusters[0].Context -n $NegativeNamespace get pod $pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>$null
        return $reason -in @('ErrImagePull', 'ImagePullBackOff')
    }
    return $pod
}

function Show-NegativeProof {
    param([string]$Pod)
    $secret = kubectl --context $Clusters[0].Context -n $NegativeNamespace get secret azure-arc-acr-pull --ignore-not-found -o name
    $podSecret = kubectl --context $Clusters[0].Context -n $NegativeNamespace get pod $Pod -o jsonpath='{.spec.imagePullSecrets[*].name}'
    $waitingReason = kubectl --context $Clusters[0].Context -n $NegativeNamespace get pod $Pod -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}'
    $warning = @(kubectl --context $Clusters[0].Context -n $NegativeNamespace get events --field-selector "involvedObject.name=$Pod,type=Warning" -o json | ConvertFrom-Json | Select-Object -ExpandProperty items | Sort-Object { $_.lastTimestamp } -Descending | Select-Object -First 1)
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
| summarize arg_max(TimeGenerated, *) by OwnerName, Uid, Kind, Name, Namespace, Category
| project TimeGenerated, OwnerName, Kind, Name, Namespace, Category,
          Phase=tostring(F['status.phase']),
          WaitingReason=tostring(F['status.containerStatuses[*].state.waiting.reason']),
          ReadyReplicas=toint(F['status.readyReplicas'])
| order by OwnerName asc, Kind asc, Name asc
"@
    try {
        $rows = az monitor log-analytics query --subscription $Subscription --workspace $WorkspaceId --analytics-query $query --timespan P1D -o json | ConvertFrom-Json
        if ($rows.Count -gt 0) {
            $rows | Select-Object OwnerName, Kind, Name, Namespace, Category, Phase, WaitingReason, ReadyReplicas, TimeGenerated | Format-Table -AutoSize -Wrap
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
    Write-Section 'Git commit: add unmapped namespace negative control'
    $started = (Get-Date).ToUniversalTime()
    $sha = Publish-Stage -Stage negative -Message 'Demo: add unmapped ACR negative control'
    $pod = Wait-NegativePod
    Write-Host "Negative control applied at $($sha.Substring(0, 7))." -ForegroundColor Green
    Show-NegativeProof -Pod $pod
    Write-Host 'AuthInjector decision:' -ForegroundColor Yellow
    Show-AuthLogs -Since $started -Pattern "namespace-not-mapped|$NegativeNamespace"
    Write-Host 'Webhook metric samples:' -ForegroundColor Yellow
    Get-MetricSample -MetricPattern '^acr_auth_webhook_admission_total\{reason="namespace-not-mapped"\}' | ForEach-Object { Write-Host $_ }
    Write-Host 'Monitoring snapshot:' -ForegroundColor Yellow
    Show-MonitoringQuery -Since $started
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
    kubectl --context $Clusters[0].Context -n $NegativeNamespace get deployment,pod --ignore-not-found
}

function Invoke-PreflightBase {
    Assert-Tooling
    Assert-CleanRepository
}

function Initialize-Demo {
    Invoke-PreflightBase
    Write-Section 'Initialize isolated negative-control Flux application'
    $existing = az k8s-configuration flux list --subscription $Subscription --resource-group $Clusters[0].ResourceGroup --cluster-name $Clusters[0].Name --cluster-type connectedClusters -o json | ConvertFrom-Json | Where-Object { $_.name -eq $NegativeFluxName }
    if (-not $existing) {
        az k8s-configuration flux create --subscription $Subscription --resource-group $Clusters[0].ResourceGroup --cluster-name $Clusters[0].Name --cluster-type connectedClusters --name $NegativeFluxName --scope cluster --namespace flux-system --kind git --url $OriginUrl --branch main --kustomization name=negative-control path=./clusters/hbroughton-acr-test-kind/negative-control prune=true sync_interval=30s retry_interval=15s timeout=20s -o table
        Assert-LastExitCode 'create negative-control Flux configuration'
    }
    else {
        az k8s-configuration flux update --subscription $Subscription --resource-group $Clusters[0].ResourceGroup --cluster-name $Clusters[0].Name --cluster-type connectedClusters --name $NegativeFluxName --kind git --url $OriginUrl --branch main --kustomization name=negative-control path=./clusters/hbroughton-acr-test-kind/negative-control prune=true sync_interval=30s retry_interval=15s timeout=20s -o none
        Assert-LastExitCode 'update negative-control Flux configuration'
        Write-Host 'Negative-control Flux configuration already exists; parameters refreshed.' -ForegroundColor DarkGray
    }
    Invoke-Preflight
}

Set-Location $RepoRoot

switch ($Action) {
    'Initialize' { Initialize-Demo }
    'Preflight' { Invoke-Preflight }
    'Prepare' { Invoke-Prepare }
    'Cleanup' { Invoke-Prepare }
    'Positive' {
        Invoke-Preflight
        Invoke-Positive
    }
    'Negative' {
        Invoke-Preflight
        Invoke-Negative
    }
    'Run' {
        Invoke-Preflight
        $positiveExists = $false
        foreach ($cluster in $Clusters) {
            foreach ($workload in $cluster.Workloads) {
                if (kubectl --context $cluster.Context -n $workload.Namespace get deployment $workload.Deployment --ignore-not-found -o name) {
                    $positiveExists = $true
                }
            }
        }
        if ($positiveExists) {
            throw 'The demo is not at baseline. Run -Action Prepare before the presentation.'
        }
        $demoStarted = (Get-Date).ToUniversalTime()
        Invoke-Positive
        if (-not $NonInteractive) {
            Read-Host 'Positive proof complete. Refresh the frontend, then press Enter for the unmapped negative control'
        }
        Invoke-Negative
        Write-Host "`nDemo complete. Refresh the frontend and compare the healthy workload application with $NegativeOwnerName." -ForegroundColor Green
        Show-MonitoringQuery -Since $demoStarted
    }
    'Status' { Show-Status }
}