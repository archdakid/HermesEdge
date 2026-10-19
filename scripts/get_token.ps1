$p = New-Object System.Diagnostics.Process
$p.StartInfo.FileName = "git.exe"
$p.StartInfo.Arguments = "credential fill"
$p.StartInfo.UseShellExecute = $false
$p.StartInfo.RedirectStandardInput = $true
$p.StartInfo.RedirectStandardOutput = $true
$p.StartInfo.CreateNoWindow = $true
[void]$p.Start()

$p.StandardInput.WriteLine("protocol=https")
$p.StandardInput.WriteLine("host=github.com")
$p.StandardInput.WriteLine("")
$out = $p.StandardOutput.ReadToEnd()
$p.WaitForExit()

if ($out -match "password=([^\r\n]+)") {
    Write-Host "TOKEN_FOUND"
    $Matches[1].Trim()
} else {
    Write-Host "TOKEN_NOT_FOUND"
}
