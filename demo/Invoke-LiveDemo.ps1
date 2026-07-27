[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Preflight', 'Prepare', 'Presenter', 'Mapped', 'Negative', 'Status', 'Cleanup', 'ShowInstallCommand')]
    [string]$Action = 'Status',
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Topology = Get-Content (Join-Path $PSScriptRoot 'topology.json') -Raw | ConvertFrom-Json
$Clusters = @($Topology.clusters)
if ($Clusters.Count -ne 1) {
    throw "The live demo requires exactly one cluster; topology.json contains $($Clusters.Count)."
}

$Cluster = $Clusters[0]
$Subscription = $Topology.subscription
$RepositoryUrl = $Topology.repositoryUrl
$FluxName = $Topology.fluxConfiguration
$AcrExtensionName = $Topology.acrAuthExtension.name
$AcrExtensionType = $Topology.acrAuthExtension.type
$AcrExtensionVersion = $Topology.acrAuthExtension.version
$AcrReleaseTrain = $Topology.acrAuthExtension.releaseTrain
$Mapped = $Topology.mappedWorkload
$Unmapped = $Topology.unmappedWorkload
$MappedPath = "clusters/$($Cluster.repoPath)/mapped-workload"
$UnmappedPath = "clusters/$($Cluster.repoPath)/unmapped-control"
$MappedKustomization = "$MappedPath/kustomization.yaml"
$UnmappedKustomization = "$UnmappedPath/kustomization.yaml"
$FluxKustomizations = @('mapped-workload', 'unmapped-control')

function Write-Banner {
    param([int]$Number, [string]$Title)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ("  {0}. {1}" -f $Number, $Title) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Good {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Bad {
    param([string]$Message)
    Write-Host "[X]  $Message" -ForegroundColor Red
}

function Write-Note {
    param([string]$Message)
    Write-Host "     $Message" -ForegroundColor DarkGray
}

function Wait-Presenter {
    param([string]$Prompt)

    if (-not $NonInteractive) {
        Read-Host $Prompt | Out-Null
    }
}

function Assert-LastExitCode {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-AzJson {
    param([string[]]$Arguments)

    $json = & az @Arguments --output json
    Assert-LastExitCode -Operation "az $($Arguments -join ' ')"
    return $json | ConvertFrom-Json
}

function Show-AcrAuthInstallCommand {
    $continuation = [char]96
    $lines = @(
        "az k8s-extension create $continuation",
        "  --subscription $Subscription $continuation",
        "  --resource-group $($Cluster.resourceGroup) $continuation",
        "  --cluster-name $($Cluster.name) $continuation",
        "  --cluster-type connectedClusters $continuation",
        "  --name $AcrExtensionName $continuation",
        "  --extension-type $AcrExtensionType $continuation",
        "  --release-train $AcrReleaseTrain $continuation",
        "  --version $AcrExtensionVersion $continuation",
        "  --auto-upgrade-minor-version false $continuation",
        "  --configuration-settings acrMap.$($Mapped.namespace)=$($Mapped.registry)"
    )

    Write-Host ($lines -join [Environment]::NewLine) -ForegroundColor Yellow
}

function Assert-Commands {
    foreach ($command in @('az', 'git', 'kubectl')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command '$command' was not found."
        }
    }

    kubectl --context $Cluster.context get namespace kube-system --output name | Out-Null
    Assert-LastExitCode -Operation "Connect to $($Cluster.context)"
}

function Assert-ManifestContract {
    $mappedManifest = Get-Content (Join-Path $RepoRoot "$MappedPath/deployment.yaml") -Raw
    $unmappedManifest = Get-Content (Join-Path $RepoRoot "$UnmappedPath/deployment.yaml") -Raw
    $expectedImage = "image: $($Mapped.registry)/$($Mapped.image)"

    foreach ($manifest in @($mappedManifest, $unmappedManifest)) {
        if ($manifest -notmatch [regex]::Escape($expectedImage)) {
            throw "Both workloads must use $($Mapped.registry)/$($Mapped.image)."
        }
        if ($manifest -match '(?m)^\s*imagePullSecrets:') {
            throw 'Git-authored workload manifests must not contain imagePullSecrets.'
        }
        if ($manifest -notmatch 'imagePullPolicy:\s*Always') {
            throw 'Both workloads must force a real private pull with imagePullPolicy: Always.'
        }
    }

    if ($Mapped.registry -ne $Unmapped.registry -or $Mapped.image -ne $Unmapped.image) {
        throw 'The mapped and unmapped workloads must use the same private image.'
    }
}

function Test-KustomizationRender {
    param([string]$Path)

    kubectl kustomize (Join-Path $RepoRoot $Path) | Out-Null
    Assert-LastExitCode -Operation "Render $Path"
}

function Get-GitSha {
    $sha = git rev-parse HEAD
    Assert-LastExitCode -Operation 'Read current Git revision'
    return $sha.Trim()
}

function Publish-Stage {
    param(
        [ValidateSet('baseline', 'mapped', 'negative')][string]$Stage,
        [string]$Message
    )

    Copy-Item (Join-Path $RepoRoot "demo/stages/$Stage/mapped-workload.yaml") (Join-Path $RepoRoot $MappedKustomization) -Force
    Copy-Item (Join-Path $RepoRoot "demo/stages/$Stage/unmapped-control.yaml") (Join-Path $RepoRoot $UnmappedKustomization) -Force
    Test-KustomizationRender -Path $MappedPath
    Test-KustomizationRender -Path $UnmappedPath

    git add -- $MappedKustomization $UnmappedKustomization
    Assert-LastExitCode -Operation "Stage $Stage manifests"
    git diff --cached --quiet -- $MappedKustomization $UnmappedKustomization
    if ($LASTEXITCODE -ne 0) {
        git commit -m $Message -- $MappedKustomization $UnmappedKustomization | Out-Host
        Assert-LastExitCode -Operation "Commit $Stage stage"
    }

    git push origin HEAD:main | Out-Host
    Assert-LastExitCode -Operation 'Push demo stage'
    return Get-GitSha
}

function Request-FluxReconcile {
    $requestedAt = [DateTime]::UtcNow.ToString('o')
    kubectl --context $Cluster.context --namespace flux-system annotate "gitrepository/$FluxName" "reconcile.fluxcd.io/requestedAt=$requestedAt" --overwrite | Out-Null
    Assert-LastExitCode -Operation 'Request Git source reconciliation'
    foreach ($name in $FluxKustomizations) {
        kubectl --context $Cluster.context --namespace flux-system annotate "kustomization/$FluxName-$name" "reconcile.fluxcd.io/requestedAt=$requestedAt" --overwrite | Out-Null
        Assert-LastExitCode -Operation "Request $name reconciliation"
    }
}

function Wait-FluxRevision {
    param([string]$GitSha, [int]$TimeoutSeconds = 240)

    Request-FluxReconcile
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $sourceRevision = kubectl --context $Cluster.context --namespace flux-system get "gitrepository/$FluxName" --output 'jsonpath={.status.artifact.revision}' 2>$null
        $allObserved = $sourceRevision -like "*$GitSha*"
        foreach ($name in $FluxKustomizations) {
            $revision = kubectl --context $Cluster.context --namespace flux-system get "kustomization/$FluxName-$name" --output 'jsonpath={.status.lastAppliedRevision}{.status.lastAttemptedRevision}' 2>$null
            $allObserved = $allObserved -and ($revision -like "*$GitSha*")
        }
        if ($allObserved) {
            Write-Good "Microsoft Flux observed exact Git revision $($GitSha.Substring(0, 7)) for both Kustomizations."
            return
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "Microsoft Flux did not observe Git revision $GitSha within $TimeoutSeconds seconds."
}

function Wait-DeploymentAbsent {
    param($Workload, [int]$TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $name = kubectl --context $Cluster.context --namespace $Workload.namespace get "deployment/$($Workload.deployment)" --ignore-not-found --output name
        if (-not $name) {
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Deployment $($Workload.namespace)/$($Workload.deployment) was not pruned."
}

function Get-PodName {
    param($Workload)

    $podName = kubectl --context $Cluster.context --namespace $Workload.namespace get pod --selector "app.kubernetes.io/name=$($Workload.deployment)" --output 'jsonpath={.items[0].metadata.name}' 2>$null
    if (-not $podName) {
        return ''
    }
    return ([string]$podName).Trim()
}

function Wait-MappedSecret {
    param([int]$TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $secret = kubectl --context $Cluster.context --namespace $Mapped.namespace get secret azure-arc-acr-pull --ignore-not-found --output name
        if ($secret) {
            Write-Good "Extension-owned pull Secret is ready in $($Mapped.namespace)."
            return
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "azure-arc-acr-pull was not provisioned in $($Mapped.namespace)."
}

function Wait-MappedWorkload {
    kubectl --context $Cluster.context --namespace $Mapped.namespace rollout status "deployment/$($Mapped.deployment)" --timeout=180s | Out-Host
    Assert-LastExitCode -Operation 'Wait for mapped workload readiness'
    $pod = Get-PodName -Workload $Mapped
    if (-not $pod) {
        throw 'The mapped workload did not create a Pod.'
    }

    $templateSecrets = kubectl --context $Cluster.context --namespace $Mapped.namespace get "deployment/$($Mapped.deployment)" --output 'jsonpath={.spec.template.spec.imagePullSecrets[*].name}'
    $podSecrets = kubectl --context $Cluster.context --namespace $Mapped.namespace get "pod/$pod" --output 'jsonpath={.spec.imagePullSecrets[*].name}'
    if ($templateSecrets) {
        throw 'The Git-authored Deployment template unexpectedly contains an imagePullSecret.'
    }
    if ($podSecrets -notmatch 'azure-arc-acr-pull') {
        throw 'AuthInjector did not add azure-arc-acr-pull to the stored Pod.'
    }

    Write-Good 'Deployment template credential reference: <none>.'
    Write-Good "Stored Pod $pod was injected with azure-arc-acr-pull."
    Write-Good 'Private image pull succeeded and the Pod is Ready.'
}

function Wait-UnmappedFailure {
    $deadline = (Get-Date).AddSeconds(180)
    $pod = ''
    $reason = ''
    do {
        $pod = Get-PodName -Workload $Unmapped
        if ($pod) {
            $reason = kubectl --context $Cluster.context --namespace $Unmapped.namespace get "pod/$pod" --output 'jsonpath={.status.containerStatuses[0].state.waiting.reason}' 2>$null
            if ($reason -in @('ErrImagePull', 'ImagePullBackOff')) {
                break
            }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if (-not $pod -or $reason -notin @('ErrImagePull', 'ImagePullBackOff')) {
        throw 'The unmapped workload did not reach ErrImagePull or ImagePullBackOff.'
    }

    $namespaceSecret = kubectl --context $Cluster.context --namespace $Unmapped.namespace get secret azure-arc-acr-pull --ignore-not-found --output name
    $podSecrets = kubectl --context $Cluster.context --namespace $Unmapped.namespace get "pod/$pod" --output 'jsonpath={.spec.imagePullSecrets[*].name}'
    if ($namespaceSecret -or $podSecrets) {
        throw 'The unmapped control unexpectedly received an ACR pull Secret.'
    }

    Write-Bad "Stored Pod $pod is $reason."
    Write-Good 'Namespace Secret: <none>; injected Pod Secret: <none>.'
    Write-Host '> Kubernetes Warning events' -ForegroundColor Yellow
    kubectl --context $Cluster.context --namespace $Unmapped.namespace get events --field-selector "involvedObject.name=$pod,type=Warning" --sort-by=.lastTimestamp | Out-Host
}

function Assert-LiveTopology {
    $config = Get-AzJson -Arguments @(
        'k8s-configuration', 'flux', 'show',
        '--subscription', $Subscription,
        '--resource-group', $Cluster.resourceGroup,
        '--cluster-name', $Cluster.name,
        '--cluster-type', 'connectedClusters',
        '--name', $FluxName
    )
    $actualKustomizations = @($config.kustomizations.PSObject.Properties.Name | Sort-Object)
    $expectedKustomizations = @($FluxKustomizations | Sort-Object)
    if (@(Compare-Object $expectedKustomizations $actualKustomizations).Count -ne 0) {
        throw "FluxConfiguration $FluxName must contain only mapped-workload and unmapped-control."
    }

    $extension = Get-AzJson -Arguments @(
        'k8s-extension', 'show',
        '--subscription', $Subscription,
        '--resource-group', $Cluster.resourceGroup,
        '--cluster-name', $Cluster.name,
        '--cluster-type', 'connectedClusters',
        '--name', $AcrExtensionName
    )
    $mappedSetting = $extension.configurationSettings.PSObject.Properties["acrMap.$($Mapped.namespace)"]
    $unmappedSetting = $extension.configurationSettings.PSObject.Properties["acrMap.$($Unmapped.namespace)"]
    if (-not $mappedSetting -or $mappedSetting.Value -ne $Mapped.registry) {
        throw "ACR Auth must map $($Mapped.namespace) to $($Mapped.registry)."
    }
    if ($unmappedSetting) {
        throw "$($Unmapped.namespace) must remain absent from acrMap."
    }

    Write-Good "One cluster: $($Cluster.name)."
    Write-Good "One Git source: $FluxName."
    Write-Good 'Two Kustomizations: mapped-workload and unmapped-control.'
    Write-Good "Only $($Mapped.namespace) is authorized for $($Mapped.registry)."
}

function Remove-FluxConfiguration {
    param([string]$ResourceGroup, [string]$ClusterName, [string]$Name)

    & az k8s-configuration flux show --subscription $Subscription --resource-group $ResourceGroup --cluster-name $ClusterName --cluster-type connectedClusters --name $Name --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "> Removing legacy FluxConfiguration $ClusterName/$Name" -ForegroundColor Yellow
        & az k8s-configuration flux delete --subscription $Subscription --resource-group $ResourceGroup --cluster-name $ClusterName --cluster-type connectedClusters --name $Name --yes --output none
        Assert-LastExitCode -Operation "Delete FluxConfiguration $ClusterName/$Name"
    }
}

function Initialize-Demo {
    Assert-Commands
    Assert-ManifestContract
    Write-Banner -Number 1 -Title 'Private ACR support installation contract'
    Show-AcrAuthInstallCommand

    $extensionArgs = @(
        'k8s-extension', 'update',
        '--subscription', $Subscription,
        '--resource-group', $Cluster.resourceGroup,
        '--cluster-name', $Cluster.name,
        '--cluster-type', 'connectedClusters',
        '--name', $AcrExtensionName,
        '--release-train', $AcrReleaseTrain,
        '--version', $AcrExtensionVersion,
        '--auto-upgrade-minor-version', 'false',
        '--configuration-settings', "acrMap.$($Mapped.namespace)=$($Mapped.registry)",
        '--yes',
        '--output', 'none'
    )
    & az @extensionArgs
    Assert-LastExitCode -Operation 'Narrow the Private ACR namespace map'

    Write-Banner -Number 2 -Title 'One Microsoft Flux source with two Kustomizations'
    Remove-FluxConfiguration -ResourceGroup $Cluster.resourceGroup -ClusterName $Cluster.name -Name 'acr-auth-negative-control'
    Remove-FluxConfiguration -ResourceGroup 'acr-auth-demo' -ClusterName 'acr-auth-demo' -Name $FluxName
    Remove-FluxConfiguration -ResourceGroup $Cluster.resourceGroup -ClusterName $Cluster.name -Name $FluxName

    $createArgs = @(
        'k8s-configuration', 'flux', 'create',
        '--subscription', $Subscription,
        '--resource-group', $Cluster.resourceGroup,
        '--cluster-name', $Cluster.name,
        '--cluster-type', 'connectedClusters',
        '--name', $FluxName,
        '--scope', 'cluster',
        '--namespace', 'flux-system',
        '--kind', 'git',
        '--url', $RepositoryUrl,
        '--branch', 'main',
        '--kustomization', 'name=mapped-workload', "path=./$MappedPath", 'prune=true', 'sync_interval=30s', 'retry_interval=15s', 'timeout=2m',
        '--kustomization', 'name=unmapped-control', "path=./$UnmappedPath", 'prune=true', 'sync_interval=30s', 'retry_interval=15s', 'timeout=30s',
        '--output', 'none'
    )
    & az @createArgs
    Assert-LastExitCode -Operation 'Create the two-Kustomization FluxConfiguration'
    Assert-LiveTopology
}

function Prepare-Demo {
    Assert-Commands
    Assert-ManifestContract
    Assert-LiveTopology
    $sha = Publish-Stage -Stage baseline -Message 'Demo reset: empty mapped and unmapped resource trees'
    Wait-FluxRevision -GitSha $sha
    Wait-DeploymentAbsent -Workload $Mapped
    Wait-DeploymentAbsent -Workload $Unmapped
    Wait-MappedSecret
    $unmappedSecret = kubectl --context $Cluster.context --namespace $Unmapped.namespace get secret azure-arc-acr-pull --ignore-not-found --output name
    if ($unmappedSecret) {
        throw 'The unmapped namespace unexpectedly contains azure-arc-acr-pull.'
    }
    kubectl --context $Cluster.context --namespace $Unmapped.namespace delete events --all --ignore-not-found | Out-Null
    Write-Good "Baseline is ready at $($sha.Substring(0, 7)); neither resource tree contains a workload."
}

function Invoke-MappedStage {
    $sha = Publish-Stage -Stage mapped -Message 'Demo: add mapped private ACR workload'
    Wait-FluxRevision -GitSha $sha
    Wait-MappedWorkload
    return $sha
}

function Invoke-NegativeStage {
    $sha = Publish-Stage -Stage negative -Message 'Demo: add unmapped private ACR control'
    Wait-FluxRevision -GitSha $sha
    Wait-UnmappedFailure
    return $sha
}

function Invoke-Presenter {
    Assert-Commands
    Assert-ManifestContract
    Assert-LiveTopology
    Wait-DeploymentAbsent -Workload $Mapped -TimeoutSeconds 5
    Wait-DeploymentAbsent -Workload $Unmapped -TimeoutSeconds 5

    Write-Banner -Number 1 -Title 'Install Private ACR support with one namespace mapping'
    Write-Host '> Registered extension installation command' -ForegroundColor Yellow
    Show-AcrAuthInstallCommand
    Write-Good "$($Mapped.namespace) is mapped to $($Mapped.registry)."
    Write-Note "$($Unmapped.namespace) is deliberately absent from acrMap."
    Wait-Presenter -Prompt 'Open mapped-workload in the monitoring blade, then press Enter'

    Write-Banner -Number 2 -Title 'Mapped resource tree: watch the healthy Pod appear'
    Write-Host "> Git image: $($Mapped.registry)/$($Mapped.image)" -ForegroundColor Yellow
    Write-Host '> Git imagePullPolicy: Always' -ForegroundColor Yellow
    Write-Host '> Git imagePullSecrets: <absent>' -ForegroundColor Yellow
    $mappedSha = Invoke-MappedStage
    Write-Note "Refresh mapped-workload. Its Deployment, ReplicaSet, and Ready Pod were created from $($mappedSha.Substring(0, 7))."
    Wait-Presenter -Prompt 'Inspect the healthy mapped tree, switch to unmapped-control, then press Enter'

    Write-Banner -Number 3 -Title 'Unmapped resource tree: watch private pull warnings appear'
    Write-Host "> Same private image: $($Unmapped.registry)/$($Unmapped.image)" -ForegroundColor Yellow
    Write-Host "> Namespace mapping for $($Unmapped.namespace): <absent>" -ForegroundColor Yellow
    $negativeSha = Invoke-NegativeStage
    Write-Note "Refresh unmapped-control. Its Pod is blocked at revision $($negativeSha.Substring(0, 7))."

    Write-Banner -Number 4 -Title 'One source, two outcomes, one authorization boundary'
    kubectl --context $Cluster.context --namespace $Mapped.namespace get deployment,pod --output wide | Out-Host
    kubectl --context $Cluster.context --namespace $Unmapped.namespace get deployment,pod --output wide | Out-Host
    Write-Good 'The mapped resource tree remains healthy.'
    Write-Bad 'The unmapped resource tree reports ImagePullBackOff and Warning events.'
    Write-Note 'The cluster, Git source, image, and deployment shape are the same; only acrMap membership changes.'
}

function Show-Status {
    Assert-Commands
    Write-Banner -Number 1 -Title 'Azure-managed GitOps topology'
    & az k8s-configuration flux show --subscription $Subscription --resource-group $Cluster.resourceGroup --cluster-name $Cluster.name --cluster-type connectedClusters --name $FluxName --query '{name:name,repository:gitRepository.url,kustomizations:kustomizations}' --output jsonc | Out-Host
    Write-Banner -Number 2 -Title 'Microsoft Flux reconciliation'
    kubectl --context $Cluster.context --namespace flux-system get "gitrepository/$FluxName" "kustomization/$FluxName-mapped-workload" "kustomization/$FluxName-unmapped-control" | Out-Host
    Write-Banner -Number 3 -Title 'Workload state'
    kubectl --context $Cluster.context --namespace $Mapped.namespace get deployment,pod --ignore-not-found --output wide | Out-Host
    kubectl --context $Cluster.context --namespace $Unmapped.namespace get deployment,pod --ignore-not-found --output wide | Out-Host
}

Push-Location $RepoRoot
try {
    switch ($Action) {
        'Initialize' { Initialize-Demo }
        'Preflight' {
            Assert-Commands
            Assert-ManifestContract
            Assert-LiveTopology
        }
        'Prepare' { Prepare-Demo }
        'Presenter' { Invoke-Presenter }
        'Mapped' {
            Assert-Commands
            Assert-LiveTopology
            Invoke-MappedStage | Out-Null
        }
        'Negative' {
            Assert-Commands
            Assert-LiveTopology
            Invoke-NegativeStage | Out-Null
        }
        'Status' { Show-Status }
        'Cleanup' { Prepare-Demo }
        'ShowInstallCommand' { Show-AcrAuthInstallCommand }
    }
}
finally {
    Pop-Location
}