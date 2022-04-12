Import-Module -Name 'hugoalh.GitHubActionsToolkit' -Scope 'Local' -ErrorAction Stop
[bool]$ConclusionFail = $false
[bool]$TargetIsLocal = $false
[string[]]$TargetList = @()
[UInt64]$TotalScanElements = 0
[UInt64]$TotalScanSize = 0
function Test-StringIsURL {
	[CmdletBinding()][OutputType([bool])]
	param (
		[Parameter(Mandatory = $true, Position = 0)][string]$InputObject
	)
	$URIObject = $InputObject -as [System.URI]
	return (($null -ne $URIObject.AbsoluteURI) -and ($InputObject -match '^https?:\/\/'))
}
Enter-GHActionsLogGroup -Title 'Import inputs.'
[string]$Target = Get-GHActionsInput -Name 'target' -Require -Trim
if ($Target -match '^\.\/$') {
	$TargetIsLocal = $true
} else {
	[string[]]$TargetListRaw = $Target -split ";|\r?\n"
	$TargetListRaw | ForEach-Object -Process {
		[string]$TargetListRawCurrent = $_.Trim()
		if ($TargetListRawCurrent.Length -gt 0) {
			if (Test-StringIsURL -InputObject $TargetListRawCurrent) {
				$TargetList += $TargetListRawCurrent
			} else {
				Write-GHActionsWarning -Message "Input ``target``'s value ``$TargetListRawCurrent`` is not a valid target!"
			}
		}
	}
}
[bool]$Deep = [bool]::Parse((Get-GHActionsInput -Name 'deep' -Require -Trim))
[bool]$ClamAVEnable = [bool]::Parse((Get-GHActionsInput -Name 'clamav_enable' -Require -Trim))
[bool]$YARAEnable = [bool]::Parse((Get-GHActionsInput -Name 'yara_enable' -Require -Trim))
Write-Host -Object (([ordered]@{
	TargetIsLocal = $TargetIsLocal
	TargetList = $TargetList -join ', '
	Deep = $Deep
	ClamAVEnable = $ClamAVEnable
	YARAEnable = $YARAEnable
} | Format-List -Property 'Value' -GroupBy 'Name' | Out-String) -replace '(?:\r?\n)+$', '')
Exit-GHActionsLogGroup
if (($TargetIsLocal -eq $false) -and ($TargetList.Length -eq 0)) {
	Write-GHActionsFail -Message "Input ``target`` does not have valid target!"
}
if ($true -notin @($ClamAVEnable, $YARAEnable)) {
	Write-GHActionsFail -Message "No anti virus software enable!"
}
Enter-GHActionsLogGroup -Title 'Update image software.'
Invoke-Expression -Command 'apk update' -ErrorAction Stop
Invoke-Expression -Command 'apk upgrade' -ErrorAction Stop
Exit-GHActionsLogGroup
if ($ClamAVEnable) {
	Enter-GHActionsLogGroup -Title 'Update ClamAV via FreshClam.'
	Invoke-Expression -Command 'freshclam' -ErrorAction Stop
	Exit-GHActionsLogGroup
	Enter-GHActionsLogGroup -Title 'Start ClamAV daemon.'
	Invoke-Expression -Command 'clamd' -ErrorAction Stop
	Exit-GHActionsLogGroup
}
function Invoke-ScanVirus {
	[CmdletBinding()][OutputType([void])]
	param (
		[Parameter(Mandatory = $true, Position = 0)][string]$Session
	)
	Write-Host -Object "Begin session $Session."
	[pscustomobject[]]$ElementsRaw = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Recurse -Force
	[pscustomobject[]]$Elements = $ElementsRaw | Sort-Object
	[string[]]$ElementsListScanFull = $Elements.FullName
	[pscustomobject[]]$ElementsListDisplay = @()
	$Elements | ForEach-Object {
		[bool]$ElementIsDirectory = Test-Path -Path $_.FullName -PathType Container
		[hashtable]$ElementListDisplay = @{
			Element = $_.FullName -replace "$env:GITHUB_WORKSPACE/", './'
			Flag = ($ElementIsDirectory ? 'D' : '')
		}
		if ($ElementIsDirectory -eq $false) {
			[UInt64]$ElementSize = $_.Length
			$ElementListDisplay.Size = $ElementSize
			$script:TotalScanSize += $ElementSize
		}
		$ElementsListDisplay += [pscustomobject]$ElementListDisplay
	}
	Enter-GHActionsLogGroup -Title "Elements ($Session) - $($Elements.Length):"
	Write-Host -Object (($ElementsListDisplay | Format-Table -Property @(
		'Element',
		'Flag',
		@{ Expression = 'Size'; Alignment = 'Right' }
	) -AutoSize -Wrap | Out-String) -replace '^(?:\r?\n)+|(?:\r?\n)+$', '')
	Exit-GHActionsLogGroup
	$script:TotalScanElements += $Elements.Length
	if ($Elements.Length -gt 0) {
		if ($ClamAVEnable) {
			[string]$ElementsScanListPath = (New-TemporaryFile).FullName
			Set-Content -Path $ElementsScanListPath -Value ($ElementsListScanFull -join "`n") -NoNewline -Encoding UTF8NoBOM
			Enter-GHActionsLogGroup -Title "ClamAV result ($Session):"
			(Invoke-Expression -Command "clamdscan --fdpass --file-list $ElementsScanListPath --multiscan") -replace "$env:GITHUB_WORKSPACE/", './'
			if ($LASTEXITCODE -eq 1) {
				Write-GHActionsError -Message "Found virus in $Session via ClamAV!"
				$script:ConclusionFail = $true
			} elseif ($LASTEXITCODE -gt 1) {
				Write-GHActionsError -Message "Unexpected ClamAV result ``$LASTEXITCODE`` in $Session!"
				$script:ConclusionFail = $true
			}
			Exit-GHActionsLogGroup
			Remove-Item -Path $ElementsScanListPath -Force -Confirm:$false
		}
		if ($YARAEnable) {

		}
	}
	Write-Host -Object "End session $Session."
}
if ($TargetIsLocal) {
	Invoke-ScanVirus -Session 'current workspace'
	if ($Deep) {
		if (Test-Path -Path '.\.git') {
			Write-Host -Object 'Import Git information.'
			[string[]]$GitCommits = Invoke-Expression -Command 'git --no-pager log --all --format=%H --reflog --reverse' -ErrorAction Stop
			if ($GitCommits.Length -le 1) {
				Write-GHActionsWarning -Message "Current Git repository has only $($GitCommits.Length) commits! If this is incorrect, please define ``actions/checkout`` input ``fetch-depth`` to ``0`` and re-trigger the workflow. (IMPORTANT: ``Re-run all jobs`` or ``Re-run this workflow`` cannot apply the modified workflow!)"
			}
			for ($GitCommitsIndex = 0; $GitCommitsIndex -lt $GitCommits.Length; $GitCommitsIndex++) {
				[string]$GitCommit = $GitCommits[$GitCommitsIndex]
				[string]$GitCurrentSession = "commit #$($GitCommitsIndex + 1)/$($GitCommits.Length) ($GitCommit)"
				Enter-GHActionsLogGroup -Title "Checkout Git $GitCurrentSession."
				Invoke-Expression -Command "git checkout $GitCommit --force --quiet"
				if ($LASTEXITCODE -eq 0) {
					Exit-GHActionsLogGroup
					Invoke-ScanVirus -Session $GitCurrentSession
				} else {
					Write-GHActionsError -Message "Unexpected Git checkout result ``$LASTEXITCODE`` in $GitCurrentSession!"
					$ConclusionFail = $true
					Exit-GHActionsLogGroup
				}
			}
		} else {
			Write-GHActionsWarning -Message 'Unable to deep scan workspace due to current workspace is not a Git repository! If this is incorrect, probably Git file is broken.'
		}
	}
} else {
	[string[]]$UselessElements = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Force -Name
	if ($UselessElements.Length -gt 0) {
		Write-GHActionsWarning -Message 'Require a clean workspace when target is network!'
		Write-Host -Object 'Clean workspace.'
		$UselessElements | ForEach-Object -Process {
			Remove-Item -Path (Join-Path -Path $env:GITHUB_WORKSPACE -ChildPath $_) -Recurse -Force -Confirm:$false
		}
	}
	foreach ($Target in ($TargetList | Sort-Object)) {
		Enter-GHActionsLogGroup -Title "Fetch file $Target."
		[string]$NetworkTemporaryFileFullPath = Join-Path -Path $env:GITHUB_WORKSPACE -ChildPath (New-Guid).Guid
		try {
			Invoke-WebRequest -Uri $Target -UseBasicParsing -Method Get -OutFile $NetworkTemporaryFileFullPath
		} catch {
			Write-GHActionsError -Message "Unable to fetch file $Target!"
			continue
		}
		Exit-GHActionsLogGroup
		Invoke-ScanVirus -Session $Target
		Remove-Item -Path $NetworkTemporaryFileFullPath -Force -Confirm:$false
	}
}
Write-Host -Object "Total scan elements: $TotalScanElements"
Write-Host -Object "Total scan size: $($TotalScanSize / 1TB) TB // $($TotalScanSize / 1GB) GB // $($TotalScanSize / 1MB) MB // $($TotalScanSize / 1KB) KB // $TotalScanSize B"
if ($ClamAVEnable) {
	Enter-GHActionsLogGroup -Title 'Stop ClamAV daemon.'
	Get-Process -Name '*clamd*' | Stop-Process
	Exit-GHActionsLogGroup
}
if ($ConclusionFail) {
	exit 1
}
exit 0
