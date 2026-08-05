from pathlib import Path

path = Path("assets/hardware_profiles_install.ps1")
text = path.read_text(encoding="utf-8-sig")

replacements = {
    '        Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot\n':
        '        $null = Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot\n',
    '    Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel" $Runtime\n':
        '    $null = Invoke-PipWithFallback $venvPython "install pip==25.1.1 setuptools wheel" $Runtime\n',
    '    Invoke-PipWithFallback $venvPython $torchPackages $Runtime -NeedsTorchIndex\n':
        '    $null = Invoke-PipWithFallback $venvPython $torchPackages $Runtime -NeedsTorchIndex\n',
    '    Invoke-PipWithFallback $venvPython ("install -r `"{0}`" -c `"{1}`"" -f $requirements, $constraints) $Runtime\n':
        '    $null = Invoke-PipWithFallback $venvPython ("install -r `"{0}`" -c `"{1}`"" -f $requirements, $constraints) $Runtime\n',
    '    Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot\n':
        '    $null = Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot\n',
    '        $environment = Install-ComfyEnvironment $installRoot $basePython $runtime\n':
        '        $environmentOutput = @(Install-ComfyEnvironment $installRoot $basePython $runtime)\n        $environment = Resolve-ComfyEnvironmentResult -Output $environmentOutput\n',
}

for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f"Expected text not found: {old!r}")
    text = text.replace(old, new, 1)

marker = "function Install-H3Models {\n"
helper = r'''function Resolve-ComfyEnvironmentResult {
    param([object[]]$Output)

    $matches = @($Output | Where-Object {
        $_ -and
        $_.PSObject.Properties["ComfyRoot"] -and
        $_.PSObject.Properties["Python"]
    })
    if ($matches.Count -ne 1) {
        $types = @($Output | ForEach-Object {
            if ($null -eq $_) { "<null>" } else { $_.GetType().FullName }
        }) -join ", "
        throw "ComfyUI environment setup returned an invalid result. Expected one environment object, received $($Output.Count) value(s): $types"
    }
    return $matches[0]
}

'''
if "function Resolve-ComfyEnvironmentResult" in text:
    raise SystemExit("Resolve-ComfyEnvironmentResult already exists")
if marker not in text:
    raise SystemExit("Install-H3Models marker not found")
text = text.replace(marker, helper + marker, 1)

path.write_text(text, encoding="utf-8")
