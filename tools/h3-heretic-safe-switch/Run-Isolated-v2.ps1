#requires -version 5.1
[CmdletBinding()]
param([string]$InstallPath="",[switch]$Rollback,[switch]$Force)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'Enable-H3-Heretic-Isolated.ps1'
if(-not(Test-Path -LiteralPath $source)){throw "Missing isolated installer: $source"}
$raw=[IO.File]::ReadAllText($source)
# Compatibility repair for the compact branch copy. The distributed ZIP contains the expanded source directly.
$raw=$raw.Replace('exit0','exit 0').Replace('exit1','exit 1')
$temp=Join-Path $env:TEMP ("H3-Heretic-Isolated-{0}.ps1"-f([guid]::NewGuid().ToString('N')))
try{
  [IO.File]::WriteAllText($temp,$raw,(New-Object Text.UTF8Encoding($true)))
  $a=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$temp)
  if($InstallPath){$a+=@('-InstallPath',$InstallPath)}
  if($Rollback){$a+='-Rollback'}
  if($Force){$a+='-Force'}
  & powershell.exe @a
  exit $LASTEXITCODE
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
