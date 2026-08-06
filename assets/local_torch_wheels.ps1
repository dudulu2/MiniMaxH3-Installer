function Find-LocalPythonWheel {
    param([string]$FileName)

    $roots = @($script:InstallerRoot, $script:AssetsRoot) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $direct = Join-Path $root $FileName
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    }

    foreach ($root in $roots) {
        $match = Get-ChildItem -LiteralPath $root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $null
}

function Install-SelectedTorchRuntime {
    param([string]$Python, $Runtime)

    $packageSpecs = @(
        [PSCustomObject]@{ Name = "torch"; Version = [string]$Runtime.torch },
        [PSCustomObject]@{ Name = "torchvision"; Version = [string]$Runtime.torchvision },
        [PSCustomObject]@{ Name = "torchaudio"; Version = [string]$Runtime.torchaudio }
    )

    $localWheels = @{}
    foreach ($package in $packageSpecs) {
        $fileName = "{0}-{1}-cp310-cp310-win_amd64.whl" -f $package.Name, $package.Version
        $wheel = Find-LocalPythonWheel -FileName $fileName
        if ($wheel) {
            $localWheels[$package.Name] = $wheel
            Add-Log ("Local wheel found for {0}: {1}" -f $package.Name, $wheel)
        }
    }

    if (-not $localWheels.ContainsKey("torch")) {
        Add-Log ("No matching local Torch wheel was found for {0}; using configured package sources." -f $Runtime.torch)
        $torchPackages = "install torch==$($Runtime.torch) torchvision==$($Runtime.torchvision) torchaudio==$($Runtime.torchaudio) --upgrade"
        $null = Invoke-PipWithFallback $Python $torchPackages $Runtime -NeedsTorchIndex
        return
    }

    Set-Stage ("Installing local Torch wheel: {0}" -f (Split-Path -Leaf $localWheels["torch"])) -1
    $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --no-deps --disable-pip-version-check" -f $localWheels["torch"]) $script:InstallerRoot

    foreach ($package in $packageSpecs | Where-Object { $_.Name -ne "torch" }) {
        if ($localWheels.ContainsKey($package.Name)) {
            Set-Stage ("Installing local {0} wheel" -f $package.Name) -1
            $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --no-deps --disable-pip-version-check" -f $localWheels[$package.Name]) $script:InstallerRoot
        } else {
            Add-Log ("No matching local {0} wheel was found; downloading only {0} {1}." -f $package.Name, $package.Version)
            $arguments = "install $($package.Name)==$($package.Version) --upgrade --no-deps"
            $null = Invoke-PipWithFallback $Python $arguments $Runtime -NeedsTorchIndex
        }
    }
}

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython, $Runtime)
    $sourceZip = Join-Path $script:AssetsRoot "ComfyUI-source.zip"
    $sourceHash = "71C2B7624D10AF93FF1158F11B1787D6296ED081B52AC86B9CA82530CE5AA754"
    if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Installer asset is missing: $sourceZip" }
    if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash -ne $sourceHash) { throw "Bundled ComfyUI source failed verification." }

    Set-Stage "Deploying fixed ComfyUI source" -1
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $InstallRoot -Force
    $comfyRoot = Join-Path $InstallRoot "ComfyUI"
    if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "ComfyUI source extraction failed." }

    $venvRoot = Join-Path $InstallRoot "runtime\venv"
    $venvPython = Join-Path $venvRoot "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Set-Stage "Creating isolated Python environment" -1
        $null = Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot
    }

    Set-Stage "Preparing pip" -1
    $null = Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel" $Runtime

    Set-Stage ("Installing {0}" -f $Runtime.label) -1
    Install-SelectedTorchRuntime -Python $venvPython -Runtime $Runtime

    $constraints = Join-Path $InstallRoot "runtime\constraints-selected.txt"
    @"
torch==$($Runtime.torch)
torchvision==$($Runtime.torchvision)
torchaudio==$($Runtime.torchaudio)
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    Set-Stage "Installing ComfyUI dependencies" -1
    $requirements = Join-Path $comfyRoot "requirements.txt"
    $null = Invoke-PipWithFallback $venvPython ("install -r `"{0}`" -c `"{1}`"" -f $requirements, $constraints) $Runtime

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='$($Runtime.torch)'; assert torchvision.__version__=='$($Runtime.torchvision)'; assert torchaudio.__version__=='$($Runtime.torchaudio)'; assert torch.cuda.is_available(); assert str(torch.version.cuda).startswith('$($Runtime.cuda_version)'); print(torch.cuda.get_device_name(0)); print('CUDA '+str(torch.version.cuda)+' ready')"
    $null = Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}
