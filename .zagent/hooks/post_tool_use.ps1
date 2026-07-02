param($payload)

try {
    $data = $payload | ConvertFrom-Json
} catch {
    exit 0
}

# Auto-format Zig files after edit
if ($data.tool -eq "edit_file" -or $data.tool -eq "write_file") {
    $path = $data.args.path
    if ($path -and ($path -like "*.zig")) {
        $out = zig fmt $path 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "fmt: $path" }
        else { Write-Host "fmt failed: $out" }
    }
}
