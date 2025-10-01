<#
.SYNOPSIS
  Validation WSL2 + Accès GPU (WSL) + Tests PyTorch/TensorFlow (optionnels) sous Windows 10.

.DESCRIPTION
  - Vérifie les fonctionnalités Windows requises (WSL + VirtualMachinePlatform).
  - Vérifie WSL: version, distributions, bascule V2, etc.
  - Vérifie le pilote NVIDIA côté Windows (nvidia-smi).
  - Vérifie la passerelle GPU côté WSL (wsl -e bash -lc "nvidia-smi").
  - Si conda & env 'dl-gpu' existent dans WSL: tests PyTorch/TensorFlow.
  - Journalise les résultats dans Validate-WSL-GPU.log.
  - Affiche PASS/FAIL par étape, avec codes couleur.

.PARAMETER Distro
  Nom de la distribution WSL à tester (par défaut: la distro par défaut).

.PARAMETER RunSmoke
  Si présent, tente des mini-tests PyTorch/TensorFlow via conda dans WSL (env 'dl-gpu').

.EXAMPLE
  PS> .\Validate-WSL-GPU-Win10.ps1 -RunSmoke

.EXAMPLE
  PS> .\Validate-WSL-GPU-Win10.ps1 -Distro "Ubuntu-22.04" -RunSmoke







  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

.\Validate-WSL-GPU-Win10.ps1




#>

[CmdletBinding()]
param(
  [string]$Distro = "",
  [switch]$RunSmoke
)

# ===================== Utilitaires =====================
$LogFile = Join-Path -Path $PSScriptRoot -ChildPath "Validate-WSL-GPU.log"
if (Test-Path $LogFile) { Remove-Item $LogFile -Force -ErrorAction SilentlyContinue }

function Log($msg) {
  $timestamp = (Get-Date).ToString("s")
  "$timestamp  $msg" | Tee-Object -FilePath $LogFile -Append
}

enum Verdict { PASS; FAIL; SKIP; INFO }

function Write-Result([Verdict]$v, [string]$msg) {
  $prefix = "{0,-5}" -f $v
  switch($v) {
    'PASS' { $fg='Green' }
    'FAIL' { $fg='Red' }
    'SKIP' { $fg='Yellow' }
    default { $fg='Cyan' }
  }
  Write-Host ("[{0}] {1}" -f $prefix, $msg) -ForegroundColor $fg
  Log ("[{0}] {1}" -f $prefix, $msg)
}

function Exec-Cmd([string]$cmd, [int]$timeoutSec=60) {
  Log (">>> " + $cmd)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.Arguments = "-NoProfile -Command `"& { $cmd }`""
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  if (-not $p.WaitForExit($timeoutSec*1000)) {
    try { $p.Kill() } catch {}
    return @{ ExitCode = 999; StdOut = ""; StdErr = "Timeout ($timeoutSec s)" }
  }
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  Log($out.TrimEnd())
  if ($err) { Log("STDERR: " + $err.TrimEnd()) }
  return @{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

# ===================== 0) Contexte système =====================
Log "# ===== Validate-WSL-GPU-Win10 ====="
Log ("OS: {0}" -f (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName)
$build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
$ubr   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
Write-Result INFO ("Windows build: {0}.{1}" -f $build, $ubr)

# ===================== 1) Fonctionnalités Windows =====================
$featWSL = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State
$featVMP = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State
if ($featWSL -eq 'Enabled') { Write-Result PASS "Feature 'Microsoft-Windows-Subsystem-Linux' activée." }
else { Write-Result FAIL "Feature WSL non activée. Activez-la via DISM et redémarrez." }

if ($featVMP -eq 'Enabled') { Write-Result PASS "Feature 'VirtualMachinePlatform' activée." }
else { Write-Result FAIL "Feature VirtualMachinePlatform non activée. Activez-la via DISM et redémarrez." }

# ===================== 2) État WSL et distributions =====================
# wsl.exe peut être ancien sur Win10; on gère les cas sans --version/--update
$hasWslVersion = $false
try {
  $r = Exec-Cmd "wsl --version"
  if ($r.ExitCode -eq 0 -and $r.StdOut) { $hasWslVersion = $true; Write-Result INFO ("wsl --version:`n" + $r.StdOut.Trim()) }
  else { Write-Result INFO "Commande 'wsl --version' non disponible (Win10 legacy) – OK." }
} catch { Write-Result INFO "Commande 'wsl --version' indisponible – OK." }

$r = Exec-Cmd "wsl -l -v"
if ($r.ExitCode -eq 0) {
  Write-Result PASS "wsl -l -v exécuté."
  Log $r.StdOut.Trim()
  $defaultLine = ($r.StdOut -split "`r?`n") | Where-Object { $_ -match "\(Default\)" }
  if (-not $Distro -and $defaultLine) {
    $Distro = ($defaultLine -replace "\s+\(Default\).*","").Trim()
    Write-Result INFO ("Distribution par défaut détectée: {0}" -f $Distro)
  }
} else {
  Write-Result FAIL "Impossible d'exécuter 'wsl -l -v'. WSL non installé ?"
}

if ($Distro) {
  $r = Exec-Cmd "wsl -l -v | Select-String -Pattern '^\s*$([Regex]::Escape($Distro))\s+([0-9]+)\s*$' -AllMatches | % { `$_.Matches }"
  $isV2 = $false
  if ($r.StdOut -match "$Distro\s+2") { $isV2 = $true }
  if ($isV2) { Write-Result PASS ("{0} est en VERSION 2." -f $Distro) }
  else { Write-Result FAIL ("{0} n'est pas en VERSION 2. Basculez: wsl --set-version {0} 2" -f $Distro) }
} else {
  Write-Result SKIP "Aucune distribution par défaut détectée. Spécifiez -Distro 'NomDistro' si besoin."
}

# ===================== 3) Pilote NVIDIA côté Windows =====================
$r = Exec-Cmd "nvidia-smi"
if ($r.ExitCode -eq 0 -and $r.StdOut -match "NVIDIA-SMI") {
  Write-Result PASS "nvidia-smi (Windows) OK. Pilote NVIDIA détecté."
  $driver = ($r.StdOut -split "`r?`n" | Select-Object -First 3) -join " "
  Write-Result INFO $driver
} else {
  Write-Result FAIL "nvidia-smi (Windows) indisponible. Installez/Mettre à jour le pilote NVIDIA GeForce."
}

# ===================== 4) Passerelle GPU dans WSL =====================
if ($Distro) {
  $r = Exec-Cmd "wsl -d `"$Distro`" -e bash -lc 'nvidia-smi'"
} else {
  $r = Exec-Cmd "wsl -e bash -lc 'nvidia-smi'"
}
if ($r.ExitCode -eq 0 -and $r.StdOut -match "NVIDIA-SMI") {
  Write-Result PASS "nvidia-smi dans WSL OK (accès GPU exposé à la distro)."
} else {
  Write-Result FAIL "nvidia-smi échoue dans WSL. Mettez à jour WSL (Store) ou redémarrez: 'wsl --shutdown'."
}

# ===================== 5) (Option) Smoke tests conda/PyTorch/TensorFlow =====================
if ($RunSmoke) {
  Write-Result INFO "Mode RunSmoke: tests rapides dans l'env conda 'dl-gpu' (si présent)."

  # 5.1 conda présent ?
  $r = Exec-Cmd "wsl -e bash -lc 'conda --version'"
  if ($r.ExitCode -eq 0) {
    Write-Result PASS "conda détecté dans WSL."
    # 5.2 env dl-gpu ?
    $r = Exec-Cmd "wsl -e bash -lc 'conda env list | grep -E ^dl-gpu'"
    if ($r.ExitCode -eq 0) {
      Write-Result PASS "Environnement conda 'dl-gpu' détecté."

      # PyTorch
      $cmdTorch = @"
wsl -e bash -lc "conda run -n dl-gpu python - << 'PY'
import torch
print('Torch version:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
print('Device count:', torch.cuda.device_count())
print('Name:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')
PY"
"@
      $r = Exec-Cmd $cmdTorch
      if ($r.ExitCode -eq 0 -and $r.StdOut -match "CUDA available:\s*True") {
        Write-Result PASS "PyTorch voit le GPU dans 'dl-gpu'."
      } else {
        Write-Result FAIL "PyTorch ne voit pas le GPU (env 'dl-gpu')."
      }

      # TensorFlow
      $cmdTF = @"
wsl -e bash -lc "conda run -n dl-gpu python - << 'PY'
import tensorflow as tf
print('TF version:', tf.__version__)
print('GPUs:', tf.config.list_physical_devices('GPU'))
PY"
"@
      $r = Exec-Cmd $cmdTF
      if ($r.ExitCode -eq 0 -and $r.StdOut -match "PhysicalDevice") {
        Write-Result PASS "TensorFlow détecte au moins un GPU dans 'dl-gpu'."
      } else {
        Write-Result FAIL "TensorFlow ne détecte pas de GPU (env 'dl-gpu')."
      }

    } else {
      Write-Result SKIP "Env conda 'dl-gpu' introuvable. Exécutez le Makefile proposé pour le créer."
    }
  } else {
    Write-Result SKIP "conda introuvable dans WSL. Passez par Miniconda/Anaconda dans votre distro."
  }
} else {
  Write-Result SKIP "RunSmoke non activé. Lancez avec -RunSmoke pour tester PyTorch/TF."
}

Write-Result INFO ("Journal: {0}" -f $LogFile)
Write-Result INFO "Validation terminée."
