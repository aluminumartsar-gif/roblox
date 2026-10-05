# Serves a folder of PNGs on http://localhost:8765/ (localhost only) so the
# Roblox Studio MCP `upload_image` tool can fetch them. Stops after 20 min.
#
# How icons get into the game (see CLAUDE.md "Icons"):
#   1. Extract the chosen PNGs from vector-icon-pack.zip into a scratch
#      folder OUTSIDE the repo (the pack license forbids redistributing them),
#      named like Robux.png (letters/digits only).
#   2. Run:  powershell -File tools/serve-icons.ps1 -Folder <that folder>
#   3. Call upload_image with http://localhost:8765/<Name>.png URLs.
#   4. Put the returned rbxassetid values in Config.Icons.
param([Parameter(Mandatory = $true)][string]$Folder)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8765/")
$listener.Start()
Write-Output "Serving $Folder on http://localhost:8765/"
$deadline = (Get-Date).AddMinutes(20)
while ($listener.IsListening -and (Get-Date) -lt $deadline) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) {
        if ((Get-Date) -ge $deadline) { break }
    }
    if (-not $task.IsCompleted) { break }
    $ctx = $task.Result
    $name = [System.IO.Path]::GetFileName($ctx.Request.Url.AbsolutePath)
    $path = Join-Path $Folder $name
    # Only plain names like Robux.png — no paths, no traversal.
    if ($name -match '^[A-Za-z0-9]+\.png$' -and (Test-Path $path)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ctx.Response.ContentType = "image/png"
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        Write-Output "200 $name"
    } else {
        $ctx.Response.StatusCode = 404
        Write-Output "404 $name"
    }
    $ctx.Response.Close()
}
$listener.Stop()
Write-Output "Stopped"
