#Requires -Version 5.1
<#
.SYNOPSIS
Select hunks from a local branch's combined changes onto a new branch from master.
.DESCRIPTION
Run from inside the repository on a branch other than master, with a clean
working tree. Creates dev/pick_yyyyMMdd_HHmmss from local master without fetching.
Requires Git on PATH. Unselected changes remain in the working tree.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# Git uses nonzero exit codes for expected results such as differing files.
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed (exit code $LASTEXITCODE): git $($args -join ' ')"
    }
}

function Confirm-Action {
    param([string]$Prompt)

    while ($true) {
        $answer = Read-Host "$Prompt [y/N]"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(n|no)$') {
            return $false
        }
        if ($answer -match '^(y|yes)$') {
            return $true
        }
        Write-Host 'Enter y or n.'
    }
}

$locationPushed = $false
$exitCode = 0
try {
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Git was not found on PATH. Install Git for Windows first.'
    }
    $repositoryRoot = & git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0) {
        throw 'Run this script from inside a Git working tree.'
    }
    Push-Location -LiteralPath $repositoryRoot
    $locationPushed = $true

    $currentBranch = & git symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Check out a branch first; HEAD is detached.'
    }
    if ($currentBranch -eq 'master') {
        throw 'Start on your unfinished branch, not master.'
    }
    & git show-ref --verify --quiet refs/heads/master
    if ($LASTEXITCODE -ne 0) {
        throw 'A local master branch is required.'
    }
    $status = @(Invoke-Git status --porcelain -uall)
    if ($status.Count -gt 0) {
        throw 'Commit or stash your changes, including untracked files, first.'
    }
    foreach ($state in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
                         'rebase-merge', 'rebase-apply', 'sequencer')) {
        $statePath = Invoke-Git rev-parse --git-path $state
        if (Test-Path -LiteralPath $statePath) {
            throw 'Finish or abort the current Git operation first.'
        }
    }

    Write-Host "Current branch: $currentBranch"
    $sourceBranch = Read-Host 'Source branch [Enter for current branch]'
    if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
        $sourceBranch = $currentBranch
    }
    $sourceRef = "refs/heads/$sourceBranch"
    & git check-ref-format $sourceRef
    if ($LASTEXITCODE -ne 0) {
        throw 'Invalid source branch name.'
    }
    if ($sourceBranch -eq 'master') {
        throw 'The source branch must not be master.'
    }
    & git show-ref --verify --quiet $sourceRef
    if ($LASTEXITCODE -ne 0) {
        throw 'The source must be an existing local branch.'
    }

    $targetBranch = 'dev/pick_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    & git show-ref --verify --quiet "refs/heads/$targetBranch"
    if ($LASTEXITCODE -eq 0) {
        throw "The target branch already exists: $targetBranch. Try again in a second."
    }
    if ($LASTEXITCODE -ne 1) {
        throw 'Could not check whether the target branch already exists.'
    }
    & git merge-base refs/heads/master $sourceRef > $null
    if ($LASTEXITCODE -ne 0) {
        throw 'The source branch and master must have a common ancestor.'
    }

    Write-Host "`nCombined source changes since its common ancestor with local master:"
    Invoke-Git diff --stat "refs/heads/master...$sourceRef" --
    Write-Host "`nNew branch: $targetBranch"
    Write-Host 'Base: local master (no fetch or pull is performed)'
    if (-not (Confirm-Action 'Continue?')) {
        Write-Host 'Cancelled.'
        return
    }

    Invoke-Git switch --no-track -c $targetBranch refs/heads/master
    & git merge --squash -- $sourceRef
    if ($LASTEXITCODE -ne 0) {
        Write-Host @'

The squash merge failed or needs conflict resolution.
Inspect git status. If there are conflicts, resolve them first.
Then continue manually from the repository root with:
  git reset
  git add -N -- .
  git add -p
  git diff --cached
  git commit
'@
        throw 'Squash merge did not complete. The working tree is preserved for inspection.'
    }
    Invoke-Git reset
    # Include new text files in interactive patch selection.
    Invoke-Git add -N -- .
    Write-Host "`nSelect hunks: y = include, n = skip, s = split, e = edit, q = finish."
    Write-Host 'Binary files must be staged separately with git add if wanted.'
    Invoke-Git add -p

    & git diff --cached --quiet
    $diffExitCode = $LASTEXITCODE
    if ($diffExitCode -eq 0) {
        Write-Host 'No changes were staged. All prepared changes remain in the working tree.'
    }
    elseif ($diffExitCode -eq 1) {
        Invoke-Git diff --cached --stat
        if (Confirm-Action 'Review the staged diff?') {
            Invoke-Git diff --cached
        }
        if (Confirm-Action 'Commit the selected changes now using your Git editor?') {
            Invoke-Git commit
        }
    }
    else {
        throw "Could not inspect staged changes (exit code $diffExitCode)."
    }

    Write-Host @'

Your original source branch is preserved.
Unselected changes remain in the working tree; inspect git status.
After committing your selection, save leftovers with:
  git reset
  git stash push -u -m "Unselected branch changes"
Build or test after putting the leftovers aside.
'@
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Stopped. Inspect git status before continuing.'
    $exitCode = 1
}
finally {
    if ($locationPushed) {
        Pop-Location
    }
}
exit $exitCode
