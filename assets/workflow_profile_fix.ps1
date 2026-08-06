function Replace-WorkflowProfileStrings {
    param([string]$Json, $Profile)

    $templateModels = [ordered]@{
        "minimax_h3_fl2va_pruned_int8_convrot.safetensors" = (Split-Path -Leaf ([string]$Profile.diffusion_model))
        "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" = (Split-Path -Leaf ([string]$Profile.text_encoder))
        "minimax_h3_video_vae_fp16.safetensors" = (Split-Path -Leaf ([string]$Profile.video_vae))
        "minimax_h3_audio_vae_fp32.safetensors" = (Split-Path -Leaf ([string]$Profile.audio_vae))
    }

    foreach ($entry in $templateModels.GetEnumerator()) {
        $Json = $Json.Replace([string]$entry.Key, [string]$entry.Value)
    }
    return $Json
}

function Assert-ProfileWorkflowModels {
    param([string]$WorkflowJson, $Profile)

    $selected = @(
        (Split-Path -Leaf ([string]$Profile.diffusion_model)),
        (Split-Path -Leaf ([string]$Profile.text_encoder)),
        (Split-Path -Leaf ([string]$Profile.video_vae)),
        (Split-Path -Leaf ([string]$Profile.audio_vae))
    )
    foreach ($name in $selected) {
        if (-not $WorkflowJson.Contains($name)) {
            throw "Generated workflow is missing the selected model reference: $name"
        }
    }

    $profileDiffusion = Split-Path -Leaf ([string]$Profile.diffusion_model)
    $knownDiffusions = @(
        "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
        "minimax_h3_fl2va_pruned_fp8_scaled.safetensors",
        "minimax_h3_fl2va_pruned_bf16.safetensors"
    )
    foreach ($name in $knownDiffusions) {
        if ($name -ne $profileDiffusion -and $WorkflowJson.Contains($name)) {
            throw "Generated workflow still references a diffusion model from another profile: $name"
        }
    }
}

function New-ProfileWorkflow {
    param([string]$ComfyRoot, $Profile)

    $workflowSource = Join-Path $script:AssetsRoot "MiniMax_H3_8GB.json"
    if (-not (Test-Path -LiteralPath $workflowSource)) { throw "Installer asset is missing: $workflowSource" }

    $rawWorkflow = Get-Content -LiteralPath $workflowSource -Raw
    $rawWorkflow = Replace-WorkflowProfileStrings -Json $rawWorkflow -Profile $Profile
    $workflow = $rawWorkflow | ConvertFrom-Json

    $resolutionNode = $workflow.nodes | Where-Object { $_.id -eq 115 } | Select-Object -First 1
    $mainNode = $workflow.nodes | Where-Object { $_.id -eq 105 } | Select-Object -First 1
    if (-not $resolutionNode -or -not $mainNode) { throw "Bundled workflow does not contain the expected profile nodes." }

    $diffusionName = Split-Path -Leaf ([string]$Profile.diffusion_model)
    $textEncoderName = Split-Path -Leaf ([string]$Profile.text_encoder)
    $videoVaeName = Split-Path -Leaf ([string]$Profile.video_vae)
    $audioVaeName = Split-Path -Leaf ([string]$Profile.audio_vae)

    $resolutionNode.widgets_values[1] = [double]$Profile.megapixels
    $mainNode.widgets_values[3] = [double]$Profile.duration_seconds
    $mainNode.widgets_values[5] = $diffusionName
    $mainNode.widgets_values[6] = $textEncoderName
    $mainNode.widgets_values[7] = $videoVaeName
    $mainNode.widgets_values[8] = $audioVaeName

    $modelNote = $workflow.nodes | Where-Object { $_.id -eq 117 } | Select-Object -First 1
    if ($modelNote) {
        $modelNote.widgets_values[0] = "## Selected model profile`n`n**Profile:** $($Profile.label)`n`n- diffusion_models/$diffusionName`n- text_encoders/$textEncoderName`n- vae/$videoVaeName`n- vae/$audioVaeName`n`nDefault output: $($Profile.resolution), $($Profile.duration_seconds) seconds at 24fps."
    }

    foreach ($subgraph in @($workflow.definitions.subgraphs)) {
        foreach ($node in @($subgraph.nodes)) {
            if ($node.type -eq "UNETLoader") {
                $node.widgets_values[0] = $diffusionName
                if ($node.properties -and $node.properties.models) {
                    foreach ($model in @($node.properties.models)) {
                        $model.name = $diffusionName
                        $model.url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$($Profile.diffusion_model)"
                        $model.directory = "diffusion_models"
                    }
                }
            }
            elseif ($node.type -eq "CLIPLoader") {
                $node.widgets_values[0] = $textEncoderName
                if ($node.properties -and $node.properties.models) {
                    foreach ($model in @($node.properties.models)) {
                        $model.name = $textEncoderName
                        $model.url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$($Profile.text_encoder)"
                        $model.directory = "text_encoders"
                    }
                }
            }
            elseif ($node.type -eq "VAELoader") {
                $isAudioVae = [string]$node.widgets_values[0] -match "audio"
                $selectedName = if ($isAudioVae) { $audioVaeName } else { $videoVaeName }
                $selectedPath = if ($isAudioVae) { [string]$Profile.audio_vae } else { [string]$Profile.video_vae }
                $node.widgets_values[0] = $selectedName
                if ($node.properties -and $node.properties.models) {
                    foreach ($model in @($node.properties.models)) {
                        $model.name = $selectedName
                        $model.url = "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/$selectedPath"
                        $model.directory = "vae"
                    }
                }
            }
        }
    }

    $workflowDir = Join-Path $ComfyRoot "user\default\workflows"
    New-Item -ItemType Directory -Force -Path $workflowDir | Out-Null
    $workflowName = "MiniMax_H3_$($Profile.id).json"
    $workflowPath = Join-Path $workflowDir $workflowName
    $workflowJson = $workflow | ConvertTo-Json -Depth 100
    Assert-ProfileWorkflowModels -WorkflowJson $workflowJson -Profile $Profile
    $workflowJson | Set-Content -LiteralPath $workflowPath -Encoding UTF8
    Add-Log "Generated profile-matched workflow: $workflowName ($diffusionName)"
    return $workflowName
}
