# Dedicated GPU memory per remote-desktop process, summed over adapters (MB).
param([int]$Samples = 1, [int]$Interval = 2)
$pattern = '^(rustdesk|SR\w+|sunshine\w*|strwinclt)$'
$peak = @{}
for ($i = 0; $i -lt $Samples; $i++) {
    $names = @{}; Get-Process | ForEach-Object { $names[[string]$_.Id] = $_.ProcessName }
    $sum = @{}
    (Get-Counter '\GPU Process Memory(*)\Dedicated Usage').CounterSamples | ForEach-Object {
        if ($_.InstanceName -match 'pid_(\d+)_') {
            $n = $names[$matches[1]]
            if ($n -match $pattern) { $sum["$n($($matches[1]))"] += $_.CookedValue }
        }
    }
    foreach ($k in $sum.Keys) { if ($sum[$k] -gt $peak[$k]) { $peak[$k] = $sum[$k] } }
    if ($i -lt $Samples - 1) { Start-Sleep $Interval }
}
$peak.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0,-28} {1,7:N1} MB' -f $_.Name, ($_.Value / 1MB) }
'{0,-28} {1,7:N1} MB' -f 'TOTAL', (($peak.Values | Measure-Object -Sum).Sum / 1MB)
