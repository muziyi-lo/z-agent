param($payload)

try {
    $data = $payload | ConvertFrom-Json
} catch {
    exit 0
}

$tool = $data.tool
$args = $data.args

# Log
$logline = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $tool"
if ($args.path) { $logline += " $($args.path)" }
Add-Content -Path "$PSScriptRoot\..\hook.log" -Value $logline

# Block writes outside workspace
if ($tool -eq "write_file" -or $tool -eq "edit_file") {
    $path = $args.path
    if ($path -and ($path -notlike "$PWD*")) {
        Write-Host "BLOCKED: $path is outside workspace"
        exit 1
    }
}

exit 0
