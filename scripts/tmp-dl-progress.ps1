$p = 'C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅\env\cache\wsl\wsl.2.7.13.0.x64.msi'
if (Test-Path -LiteralPath $p) {
    $i = Get-Item -LiteralPath $p
    'bytes={0} expected=258985984 pct={1}' -f $i.Length, [math]::Round(100.0 * $i.Length / 258985984, 2)
} else {
    'missing'
}
Get-Process curl -ErrorAction SilentlyContinue | Select-Object Id, CPU, StartTime | Format-List | Out-String
