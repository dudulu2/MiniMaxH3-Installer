# Download-route hardening layer.
# Loaded after local_torch_wheels.ps1 so these definitions intentionally override
# the generic wheel path for the final installer runtime.

function Get-TorchWheelUrls {
    param($Runtime, [string]$FileName)

    $official = ([string]$Runtime.index_url).TrimEnd('/') + "/" + $FileName
    $mirror = $null
    if ($Runtime.mirror_index_url) {
        $mirror = ([string]$Runtime.mirror_index_url).TrimEnd('/') + "/" + $FileName
    }

    # Mainland mode keeps the fastest verified route first and can fall back to
    # the official wheel endpoint without discarding a valid partial download.
    if (Test-ChinaMirrorPriority) {
        if ($mirror) { return @($mirror, $official) }
        return @($official)
    }

    # Overseas mode is deliberately official-only for PyTorch wheels. In
    # particular, do not hand a partial official download to a mainland mirror.
    return @($official)
}

function Install-SelectedTorchRuntime {
    param([string]$Python, $Runtime, [string]$InstallRoot)

    $installed = Get-InstalledTorchRuntime -Python $Python
    if (Test-TorchRuntimeMatches -Installed $installed -Runtime $Runtime) {
        Add-Log "Selected PyTorch runtime is already installed; skipping replacement."
        return
    }
    Remove-OldTorchRuntime -Python $Python -Installed $installed -Runtime $Runtime

    # Outside mainland China, let pip speak to the official PyTorch package
    # index directly. This avoids the 403/resume incompatibility observed when
    # PowerShell assembled direct wheel URLs against download.pytorch.org.
    if (-not (Test-ChinaMirrorPriority)) {
        Set-Stage ("Installing {0} from the official PyTorch index" -f $Runtime.label) -1
        Add-Log ("PyTorch download route: official pip index {0}" -f $Runtime.index_url)
        # The official PyTorch install syntax uses the base package version while
        # the selected CUDA build is determined by the cuXXX index URL.
        $torchVersion = ([string]$Runtime.torch -split '\+')[0]
        $visionVersion = ([string]$Runtime.torchvision -split '\+')[0]
        $audioVersion = ([string]$Runtime.torchaudio -split '\+')[0]
        $packages = "torch==$torchVersion torchvision==$visionVersion torchaudio==$audioVersion"
        $args = "-m pip install $packages --upgrade --index-url $($Runtime.index_url) --timeout 1800 --retries 10 --disable-pip-version-check"
        $null = Invoke-ProcessChecked $Python $args $script:InstallerRoot
        return
    }

    # Mainland China keeps the optimized standalone-wheel cache/resume path.
    # Aliyun is first, official PyTorch is fallback, and a successful cache is
    # reused on repair so the multi-gigabyte wheels are not downloaded twice.
    Add-Log "PyTorch download route: mainland mirror-optimized wheel cache"
    $packageSpecs = @(
        [PSCustomObject]@{ Name = "torch"; Version = [string]$Runtime.torch },
        [PSCustomObject]@{ Name = "torchvision"; Version = [string]$Runtime.torchvision },
        [PSCustomObject]@{ Name = "torchaudio"; Version = [string]$Runtime.torchaudio }
    )

    $cacheDir = Join-Path $InstallRoot ("downloads\torch-wheels\cu{0}-py310" -f ([string]$Runtime.cuda_version).Replace('.', ''))
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $wheels = @{}
    foreach ($package in $packageSpecs) {
        $fileName = "{0}-{1}-cp310-cp310-win_amd64.whl" -f $package.Name, $package.Version
        $wheel = Find-LocalPythonWheel -FileName $fileName
        if ($wheel) {
            Add-Log ("Local wheel found for {0}: {1}" -f $package.Name, $wheel)
        } else {
            $cached = Join-Path $cacheDir $fileName
            $urls = @(Get-TorchWheelUrls -Runtime $Runtime -FileName $fileName)
            $wheel = Invoke-ResumableTorchWheelDownload -Name ("{0} {1}" -f $package.Name, $package.Version) -Urls $urls -Destination $cached
        }
        $wheels[$package.Name] = $wheel
    }

    foreach ($package in $packageSpecs) {
        Set-Stage ("Installing local {0} wheel" -f $package.Name) -1
        $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --no-deps --disable-pip-version-check" -f $wheels[$package.Name]) $script:InstallerRoot
    }

    Set-Stage "Installing PyTorch Python dependencies" -1
    Ensure-TorchRuntimeDependencies -Python $Python
}
