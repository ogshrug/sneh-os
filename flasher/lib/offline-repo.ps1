# Sneh "full" (offline) install: resolve the complete package closure from
# the official Arch repo databases (no pacman needed - this runs on Windows),
# download every package with checksum verification, and write *trimmed*
# core.db / extra.db containing only those packages. The installer points
# pacman at this directory, so dependency resolution on the mini PC can only
# ever pick packages that are actually on the stick.

$PkgMirror = 'https://geo.mirror.pkgbuild.com'

function Read-ArchDb([string]$path, [string]$repo) {
    $list = [System.Collections.Generic.List[object]]::new()
    $fs = [IO.File]::OpenRead($path)
    try {
        $gz = [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Decompress)
        $tr = [System.Formats.Tar.TarReader]::new($gz)
        while ($null -ne ($e = $tr.GetNextEntry())) {
            if ($e.EntryType -notin 'RegularFile', 'V7RegularFile' -or -not $e.Name.EndsWith('/desc')) { continue }
            $ms = [IO.MemoryStream]::new(); $e.DataStream.CopyTo($ms)
            $bytes = $ms.ToArray()
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            $f = @{}; $key = $null
            foreach ($line in $text -split "`n") {
                if ($line -match '^%([A-Z0-9]+)%$') { $key = $Matches[1]; $f[$key] = [System.Collections.Generic.List[string]]::new(); continue }
                if ($key -and $line -ne '') { $f[$key].Add($line) }
            }
            $list.Add([pscustomobject]@{
                Name     = $f['NAME'][0]
                Repo     = $repo
                Dir      = $e.Name.Substring(0, $e.Name.Length - 5)
                Filename = $f['FILENAME'][0]
                Sha256   = $f['SHA256SUM'][0]
                CSize    = [int64]$f['CSIZE'][0]
                Depends  = if ($f.ContainsKey('DEPENDS')) { @($f['DEPENDS']) } else { @() }
                Provides = if ($f.ContainsKey('PROVIDES')) { @($f['PROVIDES']) } else { @() }
                Desc     = $bytes
            })
        }
    } finally { $fs.Dispose() }
    return $list
}

function Get-DepName([string]$dep) { return ($dep -split '[<>=:]', 2)[0].Trim() }

function Resolve-Closure([string[]]$want, $byName, $providers) {
    $sel = [ordered]@{}             # name -> pkg
    $provided = @{}                 # virtual name -> provider name (from selected set)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($w in $want) { $queue.Enqueue($w) }
    $missing = @()
    while ($queue.Count) {
        $dep = Get-DepName $queue.Dequeue()
        if (-not $dep -or $sel.Contains($dep) -or $provided.ContainsKey($dep)) { continue }
        $pkg = $null
        if ($byName.ContainsKey($dep)) { $pkg = $byName[$dep] }
        elseif ($providers.ContainsKey($dep)) {
            # same rule pacman uses with --noconfirm: first provider in repo order
            $pkg = $providers[$dep][0]
        }
        if (-not $pkg) { $missing += $dep; continue }
        if ($sel.Contains($pkg.Name)) { $provided[$dep] = $pkg.Name; continue }
        $sel[$pkg.Name] = $pkg
        foreach ($p in $pkg.Provides) { $provided[(Get-DepName $p)] = $pkg.Name }
        foreach ($d in $pkg.Depends) { $queue.Enqueue($d) }
    }
    if ($missing) { throw "unresolvable dependencies: $($missing -join ', ')" }
    return $sel.Values
}

function Get-WantedPackages([string]$root, [System.Collections.IDictionary]$cfg, [switch]$GuiOnly) {
    $read = { param($f) (Get-Content (Join-Path $root "system\packages\$f") | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }) -split '\s+' }
    $gui = $cfg['INSTALL_UI'] -eq 'gui'
    # graphical stick: the setup app itself (cage + GTK4) runs from the stick's repo
    if ($GuiOnly) { return @((& $read 'installer-gui.txt') + 'archlinux-keyring') }
    $prof = if ($cfg['PROFILE']) { $cfg['PROFILE'] } else { 'desktop' }
    $want = @() + (& $read 'base.txt') + (& $read 'desktop.txt') + (& $read "profile-$prof.txt")
    $allApps = ''
    if ($gui) {   # the edition and apps are picked later, on the machine: carry everything
        $want += (& $read 'profile-desktop.txt') + (& $read 'profile-laptop.txt') + (& $read 'installer-gui.txt')
        $allApps = (Get-Content (Join-Path $root 'system\packages\apps.txt') | Where-Object { $_ -match '^\s*[\w-]+\s*:' } | ForEach-Object { ($_ -split ':')[0].Trim() }) -join ','
    }
    $agents = if ($cfg['AGENTS']) { $cfg['AGENTS'] } else { 'claude,opencode' }
    if ($agents -ne 'none') { $want += (& $read 'agents.txt') }
    $want += if ($cfg['KERNEL']) { $cfg['KERNEL'] } else { 'linux-zen' }
    $want += 'intel-ucode', 'amd-ucode', 'archlinux-keyring'
    # every firmware split: the installer installs only what the hardware needs
    $want += Get-Content (Join-Path $root 'system\packages\firmware.txt') | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { ($_ -split '\s+')[0] }
    # optional apps: APPS=files,spotify,... (apps.txt), BROWSER=firefox counts as the firefox app
    $apps = @($(if ($allApps) { $allApps } elseif ($cfg.Contains('APPS')) { [string]$cfg['APPS'] } else { 'files,vlc,images' }) -split ',' | Where-Object { $_ })
    if ($cfg['BROWSER'] -eq 'firefox') { $apps += 'firefox' }
    foreach ($line in Get-Content (Join-Path $root 'system\packages\apps.txt')) {
        $l = ($line -replace '#.*', '').Trim()
        if ($l -notmatch '^([\w-]+)\s*:\s*(.+)$') { continue }
        if ($Matches[1] -in $apps) { $want += $Matches[2].Trim() -split '\s+' }
    }
    if ($cfg['TAILSCALE_AUTHKEY'] -or $cfg['VNC_BIND'] -eq 'tailscale') { $want += 'tailscale' }
    return $want | Select-Object -Unique
}

function Write-TrimmedDb([object[]]$pkgs, [string]$path) {
    $fs = [IO.File]::Create($path)
    try {
        $gz = [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionLevel]::Optimal)
        $tw = [System.Formats.Tar.TarWriter]::new($gz, [System.Formats.Tar.TarEntryFormat]::Ustar, $false)
        foreach ($p in $pkgs) {
            $d = [System.Formats.Tar.UstarTarEntry]::new([System.Formats.Tar.TarEntryType]::Directory, "$($p.Dir)/")
            $tw.WriteEntry($d)
            $e = [System.Formats.Tar.UstarTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, "$($p.Dir)/desc")
            $e.DataStream = [IO.MemoryStream]::new($p.Desc)
            $tw.WriteEntry($e)
        }
        $tw.Dispose(); $gz.Dispose()
    } finally { $fs.Dispose() }
}

# FAT32 cannot store ':' (package epochs, e.g. "1:2.0-1"); the installer maps %3A back.
function ConvertTo-FatName([string]$n) { return $n.Replace(':', '%3A') }

function Build-OfflineRepo([string]$root, [System.Collections.IDictionary]$cfg, [string]$outRepo, [string]$cacheDir, [switch]$GuiOnly) {
    $dbDir = Join-Path $cacheDir 'db'; $pkgCache = Join-Path $cacheDir 'pkg'
    New-Item -ItemType Directory -Force $dbDir, $pkgCache, $outRepo | Out-Null
    Write-Step $(if ($GuiOnly) { 'Graphical installer: reading Arch repo databases' } else { 'Full mode: reading Arch repo databases' })
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in 'core', 'extra') {
        $db = Join-Path $dbDir "$repo.db"
        & curl.exe -sSL --fail --retry 3 -o $db "$PkgMirror/$repo/os/x86_64/$repo.db"
        if ($LASTEXITCODE -ne 0) { Fail "could not download $repo.db" }
        $all.AddRange([object[]](Read-ArchDb $db $repo))
    }
    $byName = @{}; $providers = @{}
    foreach ($p in $all) {               # core before extra = pacman's repo order
        if (-not $byName.ContainsKey($p.Name)) { $byName[$p.Name] = $p }
        foreach ($pv in $p.Provides) {
            $n = Get-DepName $pv
            if (-not $providers.ContainsKey($n)) { $providers[$n] = [System.Collections.Generic.List[object]]::new() }
            $providers[$n].Add($p)
        }
    }
    $want = Get-WantedPackages $root $cfg -GuiOnly:$GuiOnly
    $closure = @(Resolve-Closure $want $byName $providers)
    $total = ($closure | Measure-Object CSize -Sum).Sum
    Write-Note ("{0} packages, {1:N0} MB to download (cached ones are reused)" -f $closure.Count, ($total / 1MB))

    # download (parallel) into the local cache, then verify. Cache names are FAT/NTFS-safe:
    # a ':' on NTFS would silently write an alternate data stream instead of a file.
    $todo = @($closure | Where-Object {
        $f = Join-Path $pkgCache (ConvertTo-FatName $_.Filename)
        -not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -ne $_.CSize -or
        -not (Test-Path -LiteralPath "$f.sig") })
    if ($todo) {
        $cfgFile = Join-Path $cacheDir 'curl-list.txt'
        # pacman 7 verifies every package against a detached .sig (the repo
        # databases no longer embed signatures), so fetch both.
        $lines = foreach ($p in $todo) {
            $url = "$PkgMirror/$($p.Repo)/os/x86_64/$([uri]::EscapeDataString($p.Filename))"
            $out = (Join-Path $pkgCache (ConvertTo-FatName $p.Filename)) -replace '\\', '/'
            "url = `"$url`""; "output = `"$out`""
            "url = `"$url.sig`""; "output = `"$out.sig`""
        }
        [IO.File]::WriteAllLines($cfgFile, $lines)
        Write-Step "Downloading $($todo.Count) packages (+ signatures)"
        & curl.exe -sS -L --fail --retry 5 --parallel --parallel-max 8 -K $cfgFile
        if ($LASTEXITCODE -ne 0) { Write-Note "curl reported errors ($LASTEXITCODE); verifying what arrived" }
    }
    Write-Step 'Verifying SHA-256 of every package'
    $bad = @()
    foreach ($p in $closure) {
        $f = Join-Path $pkgCache (ConvertTo-FatName $p.Filename)
        if (-not (Test-Path -LiteralPath $f) -or (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() -ne $p.Sha256 -or
            -not (Test-Path -LiteralPath "$f.sig") -or (Get-Item -LiteralPath "$f.sig").Length -lt 64) {
            Remove-Item -LiteralPath $f, "$f.sig" -ErrorAction SilentlyContinue; $bad += $p.Filename
        }
    }
    if ($bad) { Fail "$($bad.Count) packages missing or corrupt (run again to resume): $($bad[0..4] -join ', ')" }

    Write-Step "Copying packages to the stick"
    foreach ($p in $closure) {
        $src = Join-Path $pkgCache (ConvertTo-FatName $p.Filename)
        $dst = Join-Path $outRepo (ConvertTo-FatName $p.Filename)
        Copy-Item -LiteralPath $src -Destination $dst
        Copy-Item -LiteralPath "$src.sig" -Destination "$dst.sig"
    }
    foreach ($repo in 'core', 'extra') {
        Write-TrimmedDb @($closure | Where-Object Repo -eq $repo) (Join-Path $outRepo "$repo.db")
    }
    [IO.File]::WriteAllLines((Join-Path $outRepo 'closure.txt'), [string[]]($closure | ForEach-Object { "$($_.Repo)/$($_.Name)" }))
    Write-Note 'offline repo ready'
}
