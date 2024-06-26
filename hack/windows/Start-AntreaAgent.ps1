Param(
    [parameter(Mandatory = $false, HelpMessage="Kubernetes version to use")] [string] $KubernetesVersion="v1.18.0",
    [parameter(Mandatory = $false, HelpMessage="Kubernetes home path")] [string] $KubernetesHome="c:\k",
    [parameter(Mandatory = $false, HelpMessage="kubeconfig file path")] [string] $KubeConfig="c:\k\config",
    [parameter(Mandatory = $false, HelpMessage="Antrea version to use")] [string] $AntreaVersion="latest",
    [parameter(Mandatory = $false, HelpMessage="Antrea home path")] [string] $AntreaHome="c:\k\antrea",
    [parameter(Mandatory = $false, HelpMessage="Start kube-proxy")] [bool] $StartKubeProxy=$false
)
$ErrorActionPreference = "Stop"

function Get-GithubLatestReleaseTag($Owner, $Repo) {
    $ErrorActionPreference = "Stop"
    $AntreaReleases = (curl.exe -s "https://api.github.com/repos/$Owner/$Repo/releases" | ConvertFrom-Json)
    $ErrMsg = "Failed to get latest release tag for {$Owner, $Repo}"
    if (!($AntreaReleases -is [array])) {
        if ($AntreaReleases.message) {
            $ErrMsg = $ErrMsg + ", " + $AntreaReleases.message
        }
        Write-Host $ErrMsg
        return $null
    }
    foreach ($Release in $AntreaReleases) {
        if (!(($Release.tag_name.Split("-"))[-1].StartsWith("rc"))) {
            return $Release.tag_name
        }
    }
    Write-Host $ErrMsg
    return $null
}

$Owner = "antrea-io"
$Repo = "antrea"
$helper = "$AntreaHome\Helper.psm1"

if (Test-Path $helper) {
    Import-Module $helper
    # The file $helper exists means this is not the first startup.
    # We should make sure OVS services running properly to avoid host host network interruption.
    if (!(Start-OVSServices)) {
        Write-Host "Can not start OVS services, exit"
        exit 1
    }
}

if ($AntreaVersion -eq "latest") {
    $AntreaVersion = Get-GithubLatestReleaseTag $Owner $Repo
    if (!$AntreaVersion) {
        Write-Host "Failed to get Antrea latest version, exit"
        exit 1
    }
}

Write-Host "KubernetesVersion version: $KubernetesVersion"
Write-Host "Antrea version: $AntreaVersion"
$AntreaRawUrlBase = "https://raw.githubusercontent.com/$Owner/$Repo/$AntreaVersion"

if (!(Test-Path $AntreaHome)) {
    mkdir $AntreaHome
}

if (!(Test-Path $helper))
{
    curl.exe -sLo $helper "$AntreaRawUrlBase/hack/windows/Helper.psm1"
    Import-Module $helper
}

Write-Host "Checking kube-proxy and antrea-agent installation..."
if (!(Install-AntreaAgent -KubernetesVersion $KubernetesVersion -KubernetesHome $KubernetesHome -KubeConfig $KubeConfig -AntreaVersion $AntreaVersion -AntreaHome $AntreaHome)) {
    Write-Host "Failed to install antrea-agent, exit"
    exit 1
}

if ($LastExitCode) {
    Write-Host "Install antrea-agent failed, exit"
    exit 1
}

if ($StartKubeProxy) {
    Write-Host "Running Antrea with kube-proxy is no longer supported, this parameter will be removed soon"
    Write-Host "Starting kube-proxy..."
    if (!(Start-KubeProxy -KubeProxy $KubernetesHome\kube-proxy.exe -KubeConfig $KubeConfig)) {
        Write-Host "Failed to start kube-proxy, exit"
        exit 1
    } else {
        Write-Host "kube-proxy started..."
    }
}

$env:kubeconfig = $KubeConfig
$APIServer=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
$APIServer=[System.Uri]$APIServer

if ($StartKubeProxy) {
    Write-Host "Test connection to Kubernetes API server"
    $result = Test-ConnectionWithRetry $APIServer.Host $APIServer.Port 20 3
    if (!$result) {
        Write-Host "Failed to connect to Kubernetes API server service, exit"
        exit 1
    }
} else {
    sed -i "s|.*kubeAPIServerOverride:.*|kubeAPIServerOverride: \"$APIServer\"|g" C:/k/antrea/etc/antrea-agent.conf 
}

Write-Host "Starting antrea-agent..."
if (!(Start-AntreaAgent -AntreaHome $AntreaHome)) {
    Write-Host "Failed to start antrea-agent, exit"
    exit 1
} else {
    Write-Host "antrea-agent started..."
}
