$repo = 'C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅'
$py = Join-Path $repo 'env\gs-control\Scripts\python.exe'
$script = Join-Path $repo 'scripts\prepare-sfm-pilot.py'
& $py $script --repo $repo
exit $LASTEXITCODE
