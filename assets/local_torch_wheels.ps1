function Get-RuntimeIdForGpu {
    param([string]$GpuName)
    # The runtime selector loaded after this file may override this when the user
    # explicitly chooses the CUDA 12.6 compatibility channel. The automatic path
    # defaults to CUDA 13.0 for every supported GPU.
    return "cuda130"
}

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

function Get-TorchRuntimeField {
    param($Object, [string]$Name)
    if (-not $Object) { return "" }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Get-InstalledTorchRuntime {
    param([string]$Python)
    if (-not (Test-Path -LiteralPath $Python)) { return $null }

    $code = "import json; result={'torch':'','torchvision':'','torchaudio':'','cuda':''};`ntry:`n import torch; result['torch']=torch.__version__; result['cuda']=str(torch.version.cuda or '')`nexcept Exception: pass`ntry:`n import torchvision; result['torchvision']=torchvision.__version__`nexcept Exception: pass`ntry:`n import torchaudio; result['torchaudio']=torchaudio.__version__`nexcept Exception: pass`nprint(json.dumps(result))"
    try {
        $json = (& $Python -c $code 2>$null | Select-Object -Last 1)
        if (-not $json) { return $null }
        $parsed = $json | ConvertFrom-Json
        return [PSCustomObject]@{
            torch = (Get-TorchRuntimeField -Object $parsed -Name "torch")
            torchvision = (Get-TorchRuntimeField -Object $parsed -Name "torchvision")
            torchaudio = (Get-TorchRuntimeField -Object $parsed -Name "torchaudio")
            cuda = (Get-TorchRuntimeField -Object $parsed -Name "cuda")
        }
    } catch {
        return $null
    }
}

function Get-PythonToolchainState {
    param([string]$Python)
    if (-not (Test-Path -LiteralPath $Python)) { return $null }

    $code = "import json`nfrom importlib.metadata import version, PackageNotFoundError`nnames=['pip','setuptools','wheel','packaging']`nresult={}`nfor name in names:`n try: result[name]=version(name)`n except PackageNotFoundError: result[name]=''`nprint(json.dumps(result))"
    try {
        $json = (& $Python -c $code 2>$null | Select-Object -Last 1)
        if (-not $json) { return $null }
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-PythonToolchainReady {
    param($State)
    if (-not $State) { return $false }
    $pip = Get-TorchRuntimeField -Object $State -Name "pip"
    $setuptools = Get-TorchRuntimeField -Object $State -Name "setuptools"
    $wheel = Get-TorchRuntimeField -Object $State -Name "wheel"
    $packaging = Get-TorchRuntimeField -Object $State -Name "packaging"
    return (
        $pip -eq "25.1.1" -and
        -not [string]::IsNullOrWhiteSpace($setuptools) -and
        -not [string]::IsNullOrWhiteSpace($wheel) -and
        -not [string]::IsNullOrWhiteSpace($packaging)
    )
}

function Invoke-BasePyPiWithFallback {
    param([string]$Python, [string]$PackageArguments)

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
    throw "All configured Python package sources failed."
}

function Ensure-PythonToolchain {
    param([string]$Python)

    $state = Get-PythonToolchainState -Python $Python
    if (Test-PythonToolchainReady -State $state) {
        Add-Log ("Python toolchain already ready: pip {0}; setuptools {1}; wheel {2}; packaging {3}. Skipping network check." -f $state.pip, $state.setuptools, $state.wheel, $state.packaging)
        return
    }

    Add-Log "Python toolchain is missing or does not match the required baseline; installing locally required packages."
    Invoke-BasePyPiWithFallback -Python $Python -PackageArguments "install pip==25.1.1 setuptools wheel packaging"
}

function Test-ComfyRequirementsSatisfied {
    param([string]$Python, [string]$Requirements)
    if (-not (Test-Path -LiteralPath $Python) -or -not (Test-Path -LiteralPath $Requirements)) { return $false }

    $code = "import sys`nfrom pathlib import Path`nfrom importlib.metadata import version, PackageNotFoundError`nfrom packaging.requirements import Requirement`nproblems=[]`nfor raw in Path(sys.argv[1]).read_text(encoding='utf-8-sig').splitlines():`n line=raw.strip()`n if not line or line.startswith('#'): continue`n if line.startswith(('-', 'http:', 'https:', 'git+')): problems.append('unsupported:'+line); continue`n try: req=Requirement(line)`n except Exception: problems.append('unparsed:'+line); continue`n if req.marker and not req.marker.evaluate(): continue`n try: installed=version(req.name)`n except PackageNotFoundError: problems.append('missing:'+req.name); continue`n if req.specifier and installed not in req.specifier: problems.append(req.name+'='+installed+' !'+str(req.specifier))`npins={'comfyui-frontend-package':'1.47.12','comfyui-workflow-templates':'0.11.27'}`nfor name,want in pins.items():`n try: installed=version(name)`n except PackageNotFoundError: problems.append('missing:'+name); continue`n if installed != want: problems.append(name+'='+installed+' !='+want)`nsys.exit(0 if not problems else 1)"
    try {
        $null = & $Python -c $code $Requirements 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-TorchRuntimeMatches {
    param($Installed, $Runtime)
    if (-not $Installed -or -not $Runtime) { return $false }

    $installedTorch = Get-TorchRuntimeField -Object $Installed -Name "torch"
    $installedVision = Get-TorchRuntimeField -Object $Installed -Name "torchvision"
    $installedAudio = Get-TorchRuntimeField -Object $Installed -Name "torchaudio"
    $installedCuda = Get-TorchRuntimeField -Object $Installed -Name "cuda"

    if ([string]::IsNullOrWhiteSpace($installedTorch)) { return $false }
    return (
        $installedTorch -eq [string]$Runtime.torch -and
        $installedVision -eq [string]$Runtime.torchvision -and
        $installedAudio -eq [string]$Runtime.torchaudio -and
        $installedCuda -like "$($Runtime.cuda_version)*"
    )
}

function Remove-OldTorchRuntime {
    param([string]$Python, $Installed, $Runtime)
    if (-not $Installed) { return }

    $installedTorch = Get-TorchRuntimeField -Object $Installed -Name "torch"
    $installedVision = Get-TorchRuntimeField -Object $Installed -Name "torchvision"
    $installedAudio = Get-TorchRuntimeField -Object $Installed -Name "torchaudio"
    $installedCuda = Get-TorchRuntimeField -Object $Installed -Name "cuda"

    if ([string]::IsNullOrWhiteSpace($installedTorch) -and
        [string]::IsNullOrWhiteSpace($installedVision) -and
        [string]::IsNullOrWhiteSpace($installedAudio)) {
        Add-Log "No existing PyTorch runtime found; installing the selected runtime into the fresh environment."
        return
    }

    if (Test-TorchRuntimeMatches -Installed $Installed -Runtime $Runtime) {
        Add-Log "Installed PyTorch runtime already matches $($Runtime.label)."
        return
    }

    $oldSummary = "torch=$installedTorch, torchvision=$installedVision, torchaudio=$installedAudio, CUDA=$installedCuda"
    Add-Log "Existing PyTorch runtime will be upgraded in place: $oldSummary" "WARN"
    Set-Stage "Removing previous PyTorch runtime before upgrade" -1
    $null = Invoke-ProcessChecked $Python "-m pip uninstall -y torch torchvision torchaudio" $script:InstallerRoot -AllowFailure
}

function Get-TorchWheelUrls {
    param($Runtime, [string]$FileName)

    $official = ([string]$Runtime.index_url).TrimEnd('/') + "/" + $FileName
    $mirror = $null
    if ($Runtime.mirror_index_url) {
        $mirror = ([string]$Runtime.mirror_index_url).TrimEnd('/') + "/" + $FileName
    }

    if (Test-ChinaMirrorPriority) {
        if ($mirror) { return @($mirror, $official) }
        return @($official)
    }
    if ($mirror) { return @($official, $mirror) }
    return @($official)
}

function Invoke-ResumableTorchWheelDownload {
    param(
        [string]$Name,
        [string[]]$Urls,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Add-Log "Cached PyTorch wheel found: $Destination"
        return $Destination
    }

    $partial = $Destination + ".partial"
    $lastError = $null
    foreach ($url in $Urls) {
        $client = New-HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(10)
        try {
            $offset = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { [int64]0 }
            Add-Log ("Downloading {0} from {1}{2}" -f $Name, $url, $(if ($offset -gt 0) { " (resume at $([Math]::Round($offset/1MB,1)) MiB)" } else { "" }))

            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $url)
            if ($offset -gt 0) {
                $request.Headers.Range = New-Object Net.Http.Headers.RangeHeaderValue($offset, $null)
            }
            $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            if ($offset -gt 0 -and $response.StatusCode -ne [Net.HttpStatusCode]::PartialContent) {
                Add-Log "The source did not honor the resume request; restarting this wheel from zero." "WARN"
                $response.Dispose()
                $request.Dispose()
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                $offset = 0
                $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $url)
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            }
            [void]$response.EnsureSuccessStatusCode()

            $total = [int64]0
            if ($response.Content.Headers.ContentRange -and $response.Content.Headers.ContentRange.Length) {
                $total = [int64]$response.Content.Headers.ContentRange.Length
            } elseif ($response.Content.Headers.ContentLength) {
                $total = $offset + [int64]$response.Content.Headers.ContentLength
            }

            $stream = $response.Content.ReadAsStreamAsync().Result
            $mode = if ($offset -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $file = New-Object IO.FileStream($partial, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try {
                $buffer = New-Object byte[] (1MB)
                $lastUi = [DateTime]::UtcNow
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $file.Write($buffer, 0, $read)
                    $offset += $read
                    if (([DateTime]::UtcNow - $lastUi).TotalMilliseconds -ge 500) {
                        if ($total -gt 0) {
                            Set-Stage ("Downloading {0}: {1:N1}/{2:N1} MiB" -f $Name, ($offset/1MB), ($total/1MB)) ([int](100*$offset/$total))
                        } else {
                            Set-Stage ("Downloading {0}: {1:N1} MiB" -f $Name, ($offset/1MB)) -1
                        }
                        $lastUi = [DateTime]::UtcNow
                    }
                }
            } finally {
                if ($file) { $file.Dispose() }
                if ($stream) { $stream.Dispose() }
                if ($response) { $response.Dispose() }
                if ($request) { $request.Dispose() }
            }

            if ($total -gt 0 -and (Get-Item -LiteralPath $partial).Length -ne $total) {
                throw "Incomplete wheel download: expected $total bytes."
            }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Add-Log "$Name download completed and cached."
            return $Destination
        } catch {
            $lastError = $_.Exception
            Add-Log ("PyTorch wheel source failed; keeping partial data for retry/fallback: {0}" -f $_.Exception.Message) "WARN"
        } finally {
            if ($client) { $client.Dispose() }
        }
    }
    throw "All PyTorch wheel sources failed for $Name. Last error: $($lastError.Message)"
}

function Ensure-TorchRuntimeDependencies {
    param([string]$Python)

    # Install the small, ordinary Python dependencies from PyPI separately so a
    # fast Aliyun PyTorch wheel download never falls back to a slow PyPI route.
    $deps = 'install filelock "typing-extensions>=4.10.0" "sympy>=1.13.3" "networkx>=2.5.1" jinja2 "fsspec>=0.8.5" numpy "pillow!=8.3.*,>=5.3.0"'
    Invoke-BasePyPiWithFallback -Python $Python -PackageArguments $deps
}

function Install-SelectedTorchRuntime {
    param([string]$Python, $Runtime, [string]$InstallRoot)

    $installed = Get-InstalledTorchRuntime -Python $Python
    if (Test-TorchRuntimeMatches -Installed $installed -Runtime $Runtime) {
        Add-Log "Selected PyTorch runtime is already installed; skipping replacement."
        return
    }
    Remove-OldTorchRuntime -Python $Python -Installed $installed -Runtime $Runtime

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

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython, $Runtime)
    $sourceZip = Join-Path $script:AssetsRoot "ComfyUI-source.zip"
    $sourceHash = "71C2B7624D10AF93FF1158F11B1787D6296ED081B52AC86B9CA82530CE5AA754"
    if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Installer asset is missing: $sourceZip" }
    if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash -ne $sourceHash) { throw "Bundled ComfyUI source failed verification." }

    $comfyRoot = Join-Path $InstallRoot "ComfyUI"
    $existingInstall = Test-Path -LiteralPath (Join-Path $comfyRoot "main.py")
    Set-Stage $(if ($existingInstall) { "Refreshing ComfyUI application files" } else { "Deploying fixed ComfyUI source" }) -1
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $InstallRoot -Force
    if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "ComfyUI source extraction failed." }
    if ($existingInstall) { Add-Log "Existing installation detected. Models, user workflows, logs, and partial downloads are preserved." }

    $venvRoot = Join-Path $InstallRoot "runtime\venv"
    $venvPython = Join-Path $venvRoot "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Set-Stage "Creating isolated Python environment" -1
        $null = Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot
    }

    Set-Stage "Checking Python toolchain" -1
    Ensure-PythonToolchain -Python $venvPython

    Set-Stage ("Checking {0}" -f $Runtime.label) -1
    Install-SelectedTorchRuntime -Python $venvPython -Runtime $Runtime -InstallRoot $InstallRoot

    $constraints = Join-Path $InstallRoot "runtime\constraints-selected.txt"
    @"
torch==$($Runtime.torch)
torchvision==$($Runtime.torchvision)
torchaudio==$($Runtime.torchaudio)
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    $requirements = Join-Path $comfyRoot "requirements.txt"
    Set-Stage "Checking ComfyUI dependencies" -1
    if (Test-ComfyRequirementsSatisfied -Python $venvPython -Requirements $requirements) {
        Add-Log "Installed ComfyUI requirements already satisfy the bundled requirements and pinned frontend/template versions. Skipping dependency download."
    } else {
        Set-Stage "Updating ComfyUI dependencies" -1
        $dependencyArgs = "install -r `"{0}`" -c `"{1}`" --upgrade --upgrade-strategy only-if-needed" -f $requirements, $constraints
        $null = Invoke-PipWithFallback $venvPython $dependencyArgs $Runtime
    }

    Set-Stage "Checking Python dependency consistency" -1
    $null = Invoke-ProcessChecked $venvPython "-m pip check" $comfyRoot

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='$($Runtime.torch)'; assert torchvision.__version__=='$($Runtime.torchvision)'; assert torchaudio.__version__=='$($Runtime.torchaudio)'; assert torch.cuda.is_available(); assert str(torch.version.cuda).startswith('$($Runtime.cuda_version)'); print(torch.cuda.get_device_name(0)); print('CUDA '+str(torch.version.cuda)+' ready')"
    $null = Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}
