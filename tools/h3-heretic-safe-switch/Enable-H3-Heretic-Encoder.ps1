#requires -version 5.1
[CmdletBinding()]
param([string]$InstallPath="",[switch]$Rollback,[switch]$Force)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$TargetName='qwen3vl_32b_h3_ultra_heretic_int8_convrot.safetensors'
$Repos=@('ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot','ethanfel/Qwen3-VL-32B-Ultra-Heretic-MiniMax-H3-ComfyUI-INT8-ConvRot')
$OfficialRegex='^qwen3vl_32b_minimax_h3_(bf16|int8_convrot|nvfp4_awq)\.safetensors$'
$StateName='h3-heretic-switch-state.json'
$script:Root=$null

function Log([string]$m,[string]$l='INFO'){
  $s='[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$l,$m
  Write-Host $s
  if($script:Root){try{Add-Content -LiteralPath (Join-Path $script:Root 'h3-heretic-switch.log') -Value $s -Encoding UTF8}catch{}}
}
function ValidRoot([string]$p){
  if(-not $p){return $false}
  return (Test-Path (Join-Path $p 'ComfyUI\models\text_encoders'))
}
function ResolveRoot([string]$p){
  foreach($x in @($p,$env:MINIMAX_H3_HOME,'D:\MiniMaxH3','C:\MiniMaxH3','E:\MiniMaxH3','F:\MiniMaxH3')){if(ValidRoot $x){return [IO.Path]::GetFullPath($x)}}
  $d=New-Object Windows.Forms.FolderBrowserDialog
  $d.Description='请选择 MiniMax H3 安装根目录'
  if($d.ShowDialog() -eq 'OK' -and (ValidRoot $d.SelectedPath)){return [IO.Path]::GetFullPath($d.SelectedPath)}
  throw '未找到有效 MiniMax H3 安装目录。'
}
function FreeGiB([string]$p){$r=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($p));return [math]::Round((New-Object IO.DriveInfo($r)).AvailableFreeSpace/1GB,1)}
function RamGiB(){try{return [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)}catch{return 0}}
function Props($o,[string]$n){if($null -eq $o){return $null};$p=$o.PSObject.Properties[$n];if($p){return $p.Value};return $null}
function StopH3(){
  $b=Join-Path $script:Root 'Stop MiniMax H3.bat'
  if(Test-Path $b){try{Start-Process $b -WorkingDirectory $script:Root -Wait -WindowStyle Hidden}catch{}}
}
function Port8188(){try{$c=New-Object Net.Sockets.TcpClient;$a=$c.BeginConnect('127.0.0.1',8188,$null,$null);$ok=$a.AsyncWaitHandle.WaitOne(700);$r=$ok -and $c.Connected;$c.Dispose();return $r}catch{return $false}}
function FindRemote(){
  foreach($repo in $Repos){foreach($base in @('https://huggingface.co','https://hf-mirror.com')){
    try{
      Log "读取 $repo 模型清单"
      $i=Invoke-RestMethod -Uri "${base}/api/models/${repo}?blobs=true" -TimeoutSec 45 -Headers @{'User-Agent'='H3-Heretic-SafeSwitch/1.0'}
      $files=@((Props $i 'siblings')|?{([string](Props $_ 'rfilename')).ToLower().EndsWith('.safetensors')})
      $cand=@($files|?{$n=([string](Props $_ 'rfilename')).ToLower();$n -match 'int8' -and $n -match 'convrot' -and $n -notmatch 'int4|nvfp4|fp8|bf16|fp16'})
      if($cand.Count -eq 0){$cand=@($files|?{$n=([string](Props $_ 'rfilename')).ToLower();$n -match 'int8' -and $n -notmatch 'int4|nvfp4|fp8|bf16|fp16'})}
      if($cand.Count -eq 0 -and $files.Count -eq 1){$cand=$files}
      if($cand.Count -gt 0){
        $f=$cand|Sort-Object @{Expression={if(([string](Props $_ 'rfilename')) -match 'h3|minimax|pruned'){0}else{1}}},@{Expression={$s=Props $_ 'size';$l=Props $_ 'lfs';if($s){[int64]$s}elseif($l -and (Props $l 'size')){[int64](Props $l 'size')}else{[int64]::MaxValue}}}|Select-Object -First 1
        $l=Props $f 'lfs';$sha=$null;if($l){$sha=Props $l 'sha256';if(-not $sha){$o=[string](Props $l 'oid');if($o -match '^sha256:([0-9a-fA-F]{64})$'){$sha=$Matches[1]}elseif($o -match '^[0-9a-fA-F]{64}$'){$sha=$o}}}
        $size=Props $f 'size';if(-not $size -and $l){$size=Props $l 'size'}
        return [pscustomobject]@{Repo=$repo;Name=[string](Props $f 'rfilename');Size=[int64]($size??0);Sha=[string]$sha}
      }
    }catch{Log $_.Exception.Message 'WARN'}
  }}
  throw '无法确定 H3 Ultra-Heretic INT8 ConvRot 模型文件。为安全起见已停止。'
}
function Download([string]$url,[string]$dst,[int64]$size){
  $part="$dst.part";$start=0L;if(Test-Path $part){$start=(Get-Item $part).Length}
  $req=[Net.HttpWebRequest]::Create($url);$req.UserAgent='H3-Heretic-SafeSwitch/1.0';$req.Timeout=600000;$req.ReadWriteTimeout=600000
  if($start -gt 0){$req.AddRange($start)}
  try{$resp=$req.GetResponse()}catch{if($start -gt 0){Remove-Item $part -Force;return Download $url $dst $size};throw}
  try{
    $append=$start -gt 0 -and [int]$resp.StatusCode -eq 206;if(-not $append){$start=0}
    $mode=if($append){[IO.FileMode]::Append}else{[IO.FileMode]::Create}
    $i=$resp.GetResponseStream();$o=New-Object IO.FileStream($part,$mode,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$buf=New-Object byte[] (4MB);$total=$start;while(($n=$i.Read($buf,0,$buf.Length)) -gt 0){$o.Write($buf,0,$n);$total+=$n}}finally{$o.Dispose();$i.Dispose()}
  }finally{$resp.Dispose()}
  if($size -gt 0 -and (Get-Item $part).Length -ne $size){throw '下载文件大小校验失败。'}
  Move-Item $part $dst -Force
}
function SafeTensorHeader([string]$p){
  $f=[IO.File]::OpenRead($p);try{$b=New-Object byte[] 8;if($f.Read($b,0,8)-ne 8){return $false};$h=[BitConverter]::ToUInt64($b,0);return $h -gt 2 -and $h -lt 268435456 -and ($h+8) -lt [uint64]$f.Length}finally{$f.Dispose()}
}
function Workflows(){
  $a=@();foreach($d in @((Join-Path $script:Root 'workflows'),(Join-Path $script:Root 'ComfyUI\user'))){if(Test-Path $d){$a+=Get-ChildItem $d -Filter *.json -File -Recurse -ErrorAction SilentlyContinue}}
  $a+=Get-ChildItem $script:Root -Filter *.json -File -ErrorAction SilentlyContinue
  return @($a|Sort-Object FullName -Unique)
}
function Patch([string]$target,[string[]]$official){
  $hits=@();foreach($f in Workflows){try{$r=[IO.File]::ReadAllText($f.FullName);foreach($n in $official){if($r.Contains($n)){$hits+=$f;break}}}catch{}}
  if($hits.Count -eq 0){throw '没有找到引用官方 H3 encoder 的工作流，未进行任何修改。'}
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$backup=Join-Path $script:Root "backups\H3-Heretic\$stamp";New-Item -ItemType Directory -Force $backup|Out-Null
  $done=@();try{
    foreach($f in $hits){$rel=$f.FullName.Substring($script:Root.TrimEnd('\').Length+1);$bp=Join-Path $backup $rel;New-Item -ItemType Directory -Force (Split-Path $bp -Parent)|Out-Null;Copy-Item $f.FullName $bp -Force;$raw=[IO.File]::ReadAllText($f.FullName);[void]($raw|ConvertFrom-Json);foreach($n in $official){$raw=$raw.Replace($n,$target)};[void]($raw|ConvertFrom-Json);[IO.File]::WriteAllText($f.FullName,$raw,(New-Object Text.UTF8Encoding($false)));$done+=[pscustomobject]@{RelativePath=$rel;BackupPath=$bp};Log "已切换 $rel"}
    $s=[pscustomobject]@{BackupRoot=$backup;TargetEncoder=$target;OfficialEncoders=$official;ModifiedFiles=$done};$j=$s|ConvertTo-Json -Depth 6;[IO.File]::WriteAllText((Join-Path $script:Root $StateName),$j,(New-Object Text.UTF8Encoding($false)));return $s
  }catch{foreach($x in $done){Copy-Item $x.BackupPath (Join-Path $script:Root $x.RelativePath) -Force};throw}
}
function Restore($s){foreach($x in @($s.ModifiedFiles)){if(-not(Test-Path $x.BackupPath)){throw "备份缺失：$($x.BackupPath)"};Copy-Item $x.BackupPath (Join-Path $script:Root $x.RelativePath) -Force;Log "恢复 $($x.RelativePath)"}}
function VerifyStart([string]$name){
  $b=Join-Path $script:Root 'Start MiniMax H3.bat';if(-not(Test-Path $b)){Log '未找到启动 BAT，跳过在线发现检查' 'WARN';return $true}
  if(-not(Port8188)){Start-Process $b -WorkingDirectory $script:Root|Out-Null}
  $end=(Get-Date).AddMinutes(4);while((Get-Date)-lt $end){Start-Sleep 3;try{$r=Invoke-WebRequest 'http://127.0.0.1:8188/object_info' -UseBasicParsing -TimeoutSec 10;if($r.StatusCode -eq 200){return $r.Content -match [regex]::Escape($name)}}catch{}}
  return $false
}

try{
  $script:Root=ResolveRoot $InstallPath;Log "H3 根目录：$script:Root"
  $statePath=Join-Path $script:Root $StateName
  if($Rollback){StopH3;if(-not(Test-Path $statePath)){throw '没有找到可回退状态。'};$s=Get-Content $statePath -Raw|ConvertFrom-Json;Restore $s;Remove-Item $statePath -Force;Log '已恢复官方工作流。';exit 0}
  $encDir=Join-Path $script:Root 'ComfyUI\models\text_encoders';$official=@(Get-ChildItem $encDir -File|?{$_.Name -match $OfficialRegex});if($official.Count -eq 0){throw '未检测到官方 H3 Qwen encoder，拒绝修改。'}
  $ram=RamGiB;if(-not $Force -and $ram -gt 0 -and $ram -lt 48){throw "INT8 encoder 建议至少 48GB 内存；当前 $ram GB。未修改任何文件。"}
  $m=FindRemote;$need=if($m.Size -gt 0){[math]::Ceiling($m.Size/1GB)+5}else{35};if((FreeGiB $script:Root)-lt $need){throw "磁盘空间不足，至少需要约 $need GB。"}
  $dst=Join-Path $encDir $TargetName
  if(-not(Test-Path $dst)){
    $ok=$false;foreach($base in @('https://huggingface.co','https://hf-mirror.com')){try{Download "${base}/$($m.Repo)/resolve/main/$($m.Name)?download=true" $dst $m.Size;$ok=$true;break}catch{Log $_.Exception.Message 'WARN'}};if(-not $ok){throw '所有模型下载源均失败。'}
  }
  if($m.Size -gt 0 -and (Get-Item $dst).Length -ne $m.Size){throw '现有模型大小不匹配。'}
  if($m.Sha){Log '正在校验 SHA-256';$h=(Get-FileHash $dst -Algorithm SHA256).Hash;if($h.ToLower() -ne $m.Sha.ToLower()){throw '模型 SHA-256 校验失败。'}}
  if(-not(SafeTensorHeader $dst)){throw '模型 safetensors 结构校验失败。'}
  StopH3;if(Port8188){throw '8188 仍被占用。为避免误改，已停止。'}
  $s=Patch $TargetName @($official|%{$_.Name})
  if(-not(VerifyStart $TargetName)){StopH3;Restore $s;if(Test-Path $statePath){Remove-Item $statePath -Force};throw '新 encoder 未通过 ComfyUI 模型发现检查，已自动恢复官方工作流。'}
  Log 'Heretic encoder 切换完成。官方 encoder 与原工作流备份均保留。'
  [Windows.Forms.MessageBox]::Show('切换完成。官方模型未删除；如有问题运行回退脚本。','H3 Heretic Safe Switch','OK','Information')|Out-Null
}catch{Log $_.Exception.Message 'ERROR';[Windows.Forms.MessageBox]::Show($_.Exception.Message,'H3 Heretic Safe Switch','OK','Error')|Out-Null;exit 1}
