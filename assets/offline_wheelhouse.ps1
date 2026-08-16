#requires -version 5.1

# Offline-first dependency layer for the stable MiniMax H3 installer.
# This file intentionally does not change Python / PyTorch / CUDA / ComfyUI versions.
# It only changes source priority:
#   local installer + local wheelhouse -> configured network mirrors -> official sources.

function Get-LocalWheelhouseDirectories {
    $candidates = @(
        (Join-Path $script:InstallerRoot "wheels"),
        (Join-Path $script:AssetsRoot "wheels"),
        (Join-Path $script:AssetsRoot "wheels\dependencies")
    )
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
}

function Find-LocalInstallerAsset {
    param([string]$FileName)

    $candidates = @(
        (Join-Path $script:InstallerRoot $FileName),
        (Join-Path $script:AssetsRoot $FileName),
        (Join-Path $script:AssetsRoot ("wheels\" + $FileName))
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Get-Item -LiteralPath $candidate).FullName }
    }

    foreach ($root in @($script:InstallerRoot, $script:AssetsRoot)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $match = Get-ChildItem -LiteralPath $root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $null
}

function Invoke-LocalWheelhousePip {
    param(
        [string]$Python,
        [string]$PackageArguments,
        [switch]$AllowFailure
    )

    $wheelDirs = @(Get-LocalWheelhouseDirectories)
    if ($wheelDirs.Count -eq 0) {
        Add-Log "Local wheelhouse not found; network fallback may be used." "WARN"
        if ($AllowFailure) { return 1 }
        throw "Local wheelhouse is not available."
    }

    $findLinks = ($wheelDirs | ForEach-Object { "--find-links `"$_`"" }) -join " "
    Add-Log ("Trying local wheelhouse first: {0}" -f ($wheelDirs -join "; "))
    $args = "-m pip $PackageArguments --no-index $findLinks --disable-pip-version-check"
    $exit = Invoke-ProcessChecked $Python $args $script:InstallerRoot -AllowFailure
    if ($exit -eq 0) {
        Add-Log "Local wheelhouse satisfied this dependency transaction; no network source was used."
        return 0
    }

    Add-Log "Local wheelhouse is incomplete for this transaction; falling back to configured network sources." "WARN"
    if ($AllowFailure) { return [int]$exit }
    throw "Local wheelhouse could not satisfy the requested packages."
}

# Override the ordinary PyPI helper from local_torch_wheels.ps1.
function Invoke-BasePyPiWithFallback {
    param([string]$Python, [string]$PackageArguments)

    $localExit = Invoke-LocalWheelhousePip -Python $Python -PackageArguments $PackageArguments -AllowFailure
    if ($localExit -eq 0) { return }

    if (Test-ChinaMirrorPriority) {
        $sources = @(
            [PSCustomObject]@{ Label="Tsinghua PyPI mirror"; Url="https://pypi.tuna.tsinghua.edu.cn/simple" },
            [PSCustomObject]@{ Label="Aliyun PyPI mirror"; Url="https://mirrors.aliyun.com/pypi/simple" },
            [PSCustomObject]@{ Label="official PyPI"; Url="https://pypi.org/simple" }
        )
    } else {
        $sources = @(
            [PSCustomObject]@{ Label="official PyPI"; Url="https://pypi.org/simple" },
            [PSCustomObject]@{ Label="Tsinghua PyPI mirror"; Url="https://pypi.tuna.tsinghua.edu.cn/simple" },
            [PSCustomObject]@{ Label="Aliyun PyPI mirror"; Url="https://mirrors.aliyun.com/pypi/simple" }
        )
    }

    foreach ($source in $sources) {
        Add-Log "Python package source: $($source.Label)"
        $args = "-m pip $PackageArguments --index-url $($source.Url) --timeout 60 --retries 3 --disable-pip-version-check"
        $exit = Invoke-ProcessChecked $Python $args $script:InstallerRoot -AllowFailure
        if ($exit -eq 0) { return }
        Add-Log "$($source.Label) failed; trying the next Python package source." "WARN"
    }
    throw "Local wheelhouse and all configured Python package sources failed."
}

# Override the generic pip fallback used by the bundled ComfyUI requirements.
function Invoke-PipWithFallback {
    param(
        [string]$Python,
        [string]$PackageArguments,
        $Runtime,
        [switch]$NeedsTorchIndex
    )

    $localExit = Invoke-LocalWheelhousePip -Python $Python -PackageArguments $PackageArguments -AllowFailure
    if ($localExit -eq 0) { return }

    if ($NeedsTorchIndex) {
        $officialArgs = "$PackageArguments --index-url $($Runtime.index_url)"
        $mirrorArgs = if ($Runtime.mirror_index_url) { "$PackageArguments --index-url $($Runtime.mirror_index_url)" } else { $null }
        $officialLabel = "PyTorch official source"
        $mirrorLabel = "Aliyun PyTorch mirror"
    } else {
        $mirrorTorchIndex = if ($Runtime.mirror_index_url) { $Runtime.mirror_index_url } else { $Runtime.index_url }
        $officialArgs = "$PackageArguments --index-url https://pypi.org/simple --extra-index-url $($Runtime.index_url)"
        $mirrorArgs = "$PackageArguments --index-url https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url $mirrorTorchIndex"
        $officialLabel = "official PyPI"
        $mirrorLabel = "Tsinghua PyPI mirror"
    }

    $preferMirror = Test-ChinaMirrorPriority
    if ($preferMirror -and $mirrorArgs) {
        $primaryArgs = $mirrorArgs
        $primaryLabel = $mirrorLabel
        $fallbackArgs = $officialArgs
        $fallbackLabel = $officialLabel
    } else {
        $primaryArgs = $officialArgs
        $primaryLabel = $officialLabel
        $fallbackArgs = $mirrorArgs
        $fallbackLabel = $mirrorLabel
    }

    Add-Log "Python package source: $primaryLabel"
    $exit = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 2 --no-cache-dir --disable-pip-version-check" -f $primaryArgs) $script:InstallerRoot -AllowFailure
    if ($exit -eq 0) { return }

    if (-not $fallbackArgs) { throw "$primaryLabel failed and no fallback source is configured for $($Runtime.label)." }
    Add-Log "$primaryLabel failed; switching to $fallbackLabel." "WARN"
    $null = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 3 --no-cache-dir --disable-pip-version-check" -f $fallbackArgs) $script:InstallerRoot
}

# Override the Python installer step so a pre-downloaded python-3.10.11-amd64.exe
# is used before any network request.
function Install-PythonRuntime {
    param([string]$InstallRoot)

    $pythonRoot = Join-Path $InstallRoot "runtime\python"
    $python = Join-Path $pythonRoot "python.exe"
    if (Test-Path -LiteralPath $python) {
        $version = (& $python -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null)
        if ($version -eq "3.10") {
            Add-Log "Existing private Python 3.10 runtime found."
            return $python
        }
        throw "The private Python runtime exists but is not Python 3.10: $python"
    }

    $installerName = "python-3.10.11-amd64.exe"
    $localInstaller = Find-LocalInstallerAsset -FileName $installerName
    if ($localInstaller) {
        $installer = $localInstaller
        Add-Log "Local Python installer found: $installer"
        Set-Stage "Using local Python 3.10.11 installer" -1
    } else {
        $cache = Join-Path $InstallRoot "downloads"
        $installer = Join-Path $cache $installerName
        Set-Stage "Downloading Python 3.10 runtime" -1
        $mirrorFirst = Test-ChinaMirrorPriority
        $pythonUrls = if ($mirrorFirst) {
            @(
                "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe",
                "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe"
            )
        } else {
            @(
                "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
                "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe"
            )
        }
        Add-Log "Local Python installer not found; using network fallback." "WARN"
        $null = Invoke-SimpleDownload "Python 3.10.11" $pythonUrls $installer
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "The Python installer signature is not valid. File was not executed. Status: $($signature.Status)"
    }
    Add-Log "Python installer signature verified: $($signature.SignerCertificate.Subject)"

    Set-Stage "Installing private Python runtime" -1
    $arguments = "/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 Include_pip=1 TargetDir=`"$pythonRoot`""
    $null = Invoke-ProcessChecked $installer $arguments $InstallRoot
    if (-not (Test-Path -LiteralPath $python)) { throw "Python installation did not create $python" }
    return $python
}
