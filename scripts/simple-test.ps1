$ErrorActionPreference = "Stop"

$ParticipantUrl = if ($env:PARTICIPANT_URL) { $env:PARTICIPANT_URL } else { "http://localhost:8081" }
$WarmupSeconds = if ($env:WARMUP_SECONDS) { [int]$env:WARMUP_SECONDS } else { 20 }
$TestSeconds = if ($env:TEST_SECONDS) { [int]$env:TEST_SECONDS } else { 120 }
$Rps = if ($env:RPS) { [int]$env:RPS } else { 5 }
$WarmupRps = if ($env:WARMUP_RPS) { [int]$env:WARMUP_RPS } else { 2 }
$DuplicatePercent = if ($env:DUPLICATE_PERCENT) { [int]$env:DUPLICATE_PERCENT } else { 10 }
$MaxPollSeconds = if ($env:MAX_POLL_SECONDS) { [int]$env:MAX_POLL_SECONDS } else { 20 }
$SleepBetweenPolls = if ($env:SLEEP_BETWEEN_POLLS) { [int]$env:SLEEP_BETWEEN_POLLS } else { 1 }
$SampleSize = if ($env:RECONCILE_SAMPLE_SIZE) { [int]$env:RECONCILE_SAMPLE_SIZE } else { 50 }
$BacenSendTarget = if ($env:BACEN_SEND_TARGET) { [int]$env:BACEN_SEND_TARGET } else { 10000 }
$BacenReceiveTarget = if ($env:BACEN_RECEIVE_TARGET) { [int]$env:BACEN_RECEIVE_TARGET } else { 10000 }

$runId = Get-Date -Format "yyyyMMddHHmmss"
$reportDir = Join-Path $PSScriptRoot "..\reports"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$reportFile = Join-Path $reportDir "simple-test-$runId.json"

$latencies = New-Object System.Collections.Generic.List[int]
$payments = New-Object System.Collections.Generic.List[string]
$errors = 0
$idempotencyMismatches = 0

$null = Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(10)

function Get-SleepInterval([int]$rps) {
    if ($rps -le 0) { return 0.2 }
    return [Math]::Round(1.0 / $rps, 3)
}

function Send-Once($idem, $txid, $amount, $receiverKey, $clientRef) {
    $bodyObj = @{ txid = $txid; amount = $amount; receiver_key = $receiverKey; description = "teste"; client_reference = $clientRef }
    $body = ($bodyObj | ConvertTo-Json -Compress)

    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$ParticipantUrl/pix/send")
    $request.Headers.Add("Idempotency-Key", $idem)
    $request.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, "application/json")

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $sw.Stop()
        $status = [int]$response.StatusCode
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $latencies.Add([int]$sw.ElapsedMilliseconds) | Out-Null

        $paymentId = $null
        if ($content) {
            try {
                $json = $content | ConvertFrom-Json
                $paymentId = $json.payment_id
            } catch { }
        }

        return @{ PaymentId = $paymentId; Status = $status }
    } catch {
        $sw.Stop()
        $errors++
        return @{ PaymentId = $null; Status = 0 }
    }
}

function Wait-For-Participant {
    Write-Host "Aguardando participante em $ParticipantUrl/health..."
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $resp = $client.GetAsync("$ParticipantUrl/health").GetAwaiter().GetResult()
            if ([int]$resp.StatusCode -eq 200) { return }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw "Participante não respondeu em $ParticipantUrl/health"
}

function Warmup() {
    Write-Host "Warmup por ${WarmupSeconds}s em ${WarmupRps} RPS..."
    $sleep = Get-SleepInterval $WarmupRps
    $end = (Get-Date).AddSeconds($WarmupSeconds)
    $i = 0
    while ((Get-Date) -lt $end) {
        $i++
        $idem = "warmup-$runId-$i"
        $txid = "tx-w-$runId-$i"
        Send-Once $idem $txid 1000 "chave@pix" "ref-w-$i" | Out-Null
        Start-Sleep -Seconds $sleep
    }
}

function MainLoad() {
    Write-Host "Carga principal por ${TestSeconds}s em ${Rps} RPS..."
    $sleep = Get-SleepInterval $Rps
    $end = (Get-Date).AddSeconds($TestSeconds)
    $i = 0
    $rand = New-Object System.Random

    while ((Get-Date) -lt $end) {
        $i++
        $idem = "idem-$runId-$i"
        $txid = "tx-$runId-$i"
        if ($rand.Next(0, 100) -lt $DuplicatePercent) {
            $res1 = Send-Once $idem $txid 1500 "chave@pix" "ref-$i"
            $res2 = Send-Once $idem $txid 1500 "chave@pix" "ref-$i"
            if ($res1.PaymentId -and $res2.PaymentId -and $res1.PaymentId -ne $res2.PaymentId) {
                $idempotencyMismatches++
            }
            if ($res1.PaymentId) { $payments.Add($res1.PaymentId) | Out-Null }
        } else {
            $res = Send-Once $idem $txid 1500 "chave@pix" "ref-$i"
            if ($res.PaymentId) { $payments.Add($res.PaymentId) | Out-Null }
        }
        Start-Sleep -Seconds $sleep
    }
}

function Reconcile() {
    Write-Host "Reconciliação (poll) por até ${MaxPollSeconds}s por pagamento..."
    $finalized = 0
    $pending = 0

    $sample = $payments
    if ($payments.Count -gt $SampleSize) {
        $sample = $payments | Select-Object -First $SampleSize
    }

    foreach ($paymentId in $sample) {
        if (-not $paymentId) { continue }
        $start = Get-Date
        $done = $false
        while ((Get-Date) -lt $start.AddSeconds($MaxPollSeconds)) {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "$ParticipantUrl/pix/send/$paymentId")
            try {
                $resp = $client.SendAsync($req).GetAwaiter().GetResult()
                if ([int]$resp.StatusCode -eq 200) {
                    $content = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $status = $null
                    if ($content) {
                        try { $status = ($content | ConvertFrom-Json).status } catch { }
                    }
                    if ($status -and $status -ne "PENDING" -and $status -ne "SENT" -and $status -ne "CREATED") {
                        $finalized++
                        $done = $true
                        break
                    }
                }
            } catch { }
            Start-Sleep -Seconds $SleepBetweenPolls
        }
        if (-not $done) { $pending++ }
    }

    return @{ Finalized = $finalized; Pending = $pending }
}

function Get-Percentile([int[]]$values, [int]$percent) {
    if (-not $values -or $values.Length -eq 0) { return 0 }
    $sorted = $values | Sort-Object
    $index = [Math]::Ceiling(($sorted.Length * $percent) / 100)
    if ($index -lt 1) { $index = 1 }
    if ($index -gt $sorted.Length) { $index = $sorted.Length }
    return $sorted[$index - 1]
}

function Check-Ledger {
    $result = @{ Status = "missing"; InvalidPostings = 0; DuplicatePostings = 0; NegativeBalances = 0 }

    try {
        $entriesResp = $client.GetAsync("$ParticipantUrl/ledger/entries").GetAwaiter().GetResult()
        if ([int]$entriesResp.StatusCode -ne 200) { return $result }
        $entriesJson = $entriesResp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $result.Status = "checked"

        $postingIds = @{}
        foreach ($entry in $entriesJson.entries) {
            $debits = 0
            $credits = 0
            foreach ($line in $entry.lines) {
                if ($line.direction -eq "DEBIT") { $debits += [int64]$line.amount }
                if ($line.direction -eq "CREDIT") { $credits += [int64]$line.amount }
            }
            if ($debits -ne $credits) { $result.InvalidPostings++ }
            if ($postingIds.ContainsKey($entry.posting_id)) { $result.DuplicatePostings++ }
            $postingIds[$entry.posting_id] = $true
        }

        $balancesResp = $client.GetAsync("$ParticipantUrl/ledger/balances").GetAwaiter().GetResult()
        if ([int]$balancesResp.StatusCode -eq 200) {
            $balancesJson = $balancesResp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            foreach ($bal in $balancesJson.balances) {
                if ([int64]$bal.amount -lt 0) { $result.NegativeBalances++ }
            }
        }
    } catch { }

    return $result
}

Wait-For-Participant
Warmup
MainLoad
$recon = Reconcile

$totalRequests = $latencies.Count
$p95 = Get-Percentile $latencies.ToArray() 95
$p99 = Get-Percentile $latencies.ToArray() 99

$ledger = Check-Ledger

$successRate = if (($recon.Finalized + $recon.Pending) -gt 0) { [Math]::Round($recon.Finalized / ($recon.Finalized + $recon.Pending), 4) } else { 0 }
$errorRate = if ($totalRequests -gt 0) { [Math]::Round($errors / $totalRequests, 4) } else { 0 }
$idemRate = if ($totalRequests -gt 0) { [Math]::Round($idempotencyMismatches / $totalRequests, 4) } else { 0 }

$p95Penalty = if ($p95 -gt 200) { [Math]::Round(($p95 - 200) * 0.10, 4) } else { 0 }
$p99Penalty = if ($p99 -gt 500) { [Math]::Round(($p99 - 500) * 0.05, 4) } else { 0 }

$resilienceScore = [Math]::Max(0, [Math]::Min(100, [int](100 * ($successRate - $errorRate - $idemRate))))
$stateScore = [Math]::Max(0, [Math]::Min(100, [int](100 * $successRate)))
$perfScore = [Math]::Max(0, [Math]::Min(100, [int](100 - $p95Penalty - $p99Penalty)))

$latencyPenalty = 0
$perfScoreClamped = [Math]::Max(0, [Math]::Min(100, (100 - $p95Penalty - $p99Penalty)))
$latencyPenalty = [Math]::Round(1 - ($perfScoreClamped / 100), 4)
$overallScore = [Math]::Max(0, [Math]::Min(100, [int](100 * (0.55 * $successRate - 0.25 * $errorRate - 0.20 * $latencyPenalty))))

$ledgerOk = $false
$ledgerScore = 0
if ($ledger.Status -eq "checked") {
    if ($ledger.InvalidPostings -eq 0 -and $ledger.DuplicatePostings -eq 0 -and $ledger.NegativeBalances -eq 0) {
        $ledgerOk = $true
        $ledgerScore = 100
    }
}

$approved = $false
if ($ledgerOk -and $resilienceScore -ge 70 -and $stateScore -ge 70) { $approved = $true }

$report = [ordered]@{
    participant_url = $ParticipantUrl
    warmup_seconds = $WarmupSeconds
    test_seconds = $TestSeconds
    rps = $Rps
    duplicate_percent = $DuplicatePercent
    bacen_send_target = $BacenSendTarget
    bacen_receive_target = $BacenReceiveTarget
    total_requests = $totalRequests
    http_errors = $errors
    idempotency_mismatches = $idempotencyMismatches
    latency_ms_p95 = $p95
    latency_ms_p99 = $p99
    finalized = $recon.Finalized
    pending = $recon.Pending
    ledger = [ordered]@{
        status = $ledger.Status
        ok = $ledgerOk
        invalid_postings = $ledger.InvalidPostings
        duplicate_postings = $ledger.DuplicatePostings
        negative_balances = $ledger.NegativeBalances
    }
    scores = [ordered]@{
        overall = $overallScore
        ledger = $ledgerScore
        resilience = $resilienceScore
        states = $stateScore
        operations = 0
        performance = $perfScore
    }
    penalties = [ordered]@{
        latency = $latencyPenalty
        p95 = $p95Penalty
        p99 = $p99Penalty
    }
    calc = [ordered]@{
        success_rate = $successRate
        error_rate = $errorRate
        idempotency_rate = $idemRate
        latency_penalty = $latencyPenalty
        total_finalized = ($recon.Finalized + $recon.Pending)
    }
    notes = [ordered]@{
        operations = "manual_review"
        ledger_requires_jq = $true
    }
    approved = $approved
}

$report | ConvertTo-Json -Depth 6 | Out-File -Encoding UTF8 $reportFile
Write-Host "Relatório gerado em: $reportFile"

$successPercent = [Math]::Round($successRate * 100, 2)
if ($approved) {
    Write-Host "Resultado: APROVADO ($successPercent% de sucesso)"
} else {
    Write-Host "Resultado: REPROVADO ($successPercent% de sucesso)"
}
Write-Host "Cálculo: S=$successRate E=$errorRate L=$latencyPenalty p95_pen=$p95Penalty p99_pen=$p99Penalty overall=$overallScore"
