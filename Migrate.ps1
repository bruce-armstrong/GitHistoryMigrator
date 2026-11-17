<#
.SYNOPSIS
    Moves a PowerBuilder 2025 repository from Workspace mode to Solution mode
    without losing its git history.

.DESCRIPTION
    Workspace mode keeps the source in PBL files and exports it to ws_objects;
    Solution mode keeps it as text files in .pbl folders.

    inplace  Adds two commits on a new branch of the repository:
               1. a pure rename commit: every ws_objects/<path>/<lib>.pbl.src/<obj>
                  moves to <path>/<lib>.pbl/<obj> unchanged, so git sees each
                  move as a 100% rename;
               2. a conversion commit: export headers rewritten, .pbw/.pbt files
                  replaced by .pbsln/.pbproj files, a .pblmeta file per library,
                  and a !*.pbl/ negation after any .gitignore pattern such as
                  *.pbl, so the new .pbl folders aren't ignored.
             Existing commits, branches and hashes are untouched.

    rewrite  Builds a NEW repository in which every commit is rewritten as if
             the project had always been in Solution mode. The source repository
             is only read. Commit hashes change; a map of old to new is written.

    -IdeOutput (both modes): the folder PowerBuilder's own migration wrote. Its
    solution files are committed on top, so the final tree is exactly what the
    IDE produced (including .bin files for objects with OLE binary data).

    Runs on Windows PowerShell 5.1 and PowerShell 7. Requires git 2.23+.

.EXAMPLE
    .\Migrate.ps1 inplace C:\src\my-repo-clone

.EXAMPLE
    .\Migrate.ps1 rewrite C:\src\my-repo-clone -Output C:\src\my-repo-solution

.EXAMPLE
    .\Migrate.ps1 inplace C:\src\my-repo-clone -IdeOutput C:\temp\ide-migrated
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('inplace', 'rewrite')]
    [string]$Mode,

    # The Workspace-mode repository (in rewrite mode it is only read).
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Repo,

    # inplace: the new branch.
    [string]$Branch = 'migrate-to-solution',

    # rewrite: a new, empty folder for the rewritten repository.
    [string]$Output,

    # Folder written by PowerBuilder's own migration, committed on top.
    [string]$IdeOutput,

    # inplace: folder to move untracked local .pbl files into.
    [string]$MovePblsTo,

    [string]$MessageRename,
    [string]$MessageConvert
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# All file content is handled as "Latin-1 strings": one char per byte, so
# string operations are byte-exact and nothing is ever re-encoded by accident.
$script:L1 = [Text.Encoding]::GetEncoding(28591)
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:Utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$script:BOM = [string][char]0xEF + [char]0xBB + [char]0xBF
$script:SourceExts = @('.sra', '.srd', '.srf', '.srj', '.srm', '.srp', '.srq', '.srs', '.sru', '.srw', '.srx')
$script:PblVersion = '250'                                            # PowerBuilder 2025
$script:PblComment = 'Created from Source Control Refresh Operation'  # what the IDE writes
$script:Ord = [StringComparison]::Ordinal
$script:GitignoreNote = '# Solution mode: .pbl entries are source folders, not binary libraries'

function Stop-Migration([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Resolve-UserPath([string]$Path) {
    if (-not $Path) { return $null }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-Prefix([string]$s, [string]$prefix) { $s.StartsWith($prefix, $script:Ord) }
function Test-Suffix([string]$s, [string]$suffix) { $s.ToLowerInvariant().EndsWith($suffix, $script:Ord) }

function Get-Ext([string]$path) {
    $name = $path.Substring($path.LastIndexOf('/') + 1)
    $i = $name.LastIndexOf('.')
    if ($i -le 0) { return '' }
    $name.Substring($i).ToLowerInvariant()
}

function Set-Ext([string]$path, [string]$ext) {
    $slash = [Math]::Max($path.LastIndexOf('/'), $path.LastIndexOf('\'))
    $i = $path.LastIndexOf('.')
    if ($i -gt $slash + 1) { return $path.Substring(0, $i) + $ext }
    $path + $ext
}

# --------------------------------------------------------------------------
# Running git
# --------------------------------------------------------------------------

function ConvertTo-WinArg([string]$a) {
    # Quote one argument the way CommandLineToArgvW / the C runtime parse it.
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $a.ToCharArray()) {
        if ($c -ceq [char]'\') { $bs++; continue }
        if ($c -ceq [char]'"') {
            [void]$sb.Append('\' * ($bs * 2 + 1)).Append('"')
        } else {
            [void]$sb.Append('\' * $bs).Append($c)
        }
        $bs = 0
    }
    [void]$sb.Append('\' * ($bs * 2)).Append('"')
    $sb.ToString()
}

function Start-Git([string[]]$GitArgs, [bool]$In, [bool]$Out, [bool]$Err) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($GitArgs | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $In
    $psi.RedirectStandardOutput = $Out
    $psi.RedirectStandardError = $Err
    if ($Err) { $psi.StandardErrorEncoding = $script:Utf8 }
    $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    [Diagnostics.Process]::Start($psi)
}

function Invoke-Git([string]$RepoPath, [string[]]$GitArgs, [byte[]]$InputBytes = $null, [switch]$AllowFail) {
    $all = if ($RepoPath) { @('-C', $RepoPath) + $GitArgs } else { $GitArgs }
    $p = Start-Git $all ($null -ne $InputBytes) $true $true
    $errTask = $p.StandardError.ReadToEndAsync()
    $ms = New-Object IO.MemoryStream
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    if ($null -ne $InputBytes) {
        $s = $p.StandardInput.BaseStream
        $s.Write($InputBytes, 0, $InputBytes.Length)
        $s.Close()
    }
    $outTask.Wait()
    $p.WaitForExit()
    $r = [pscustomobject]@{ Code = $p.ExitCode; Out = $ms.ToArray(); Err = $errTask.Result }
    if ($r.Code -ne 0 -and -not $AllowFail) {
        Stop-Migration ("git {0} failed:`n{1}" -f ($GitArgs -join ' '), $r.Err)
    }
    $r
}

function Get-GitText([string]$RepoPath, [string[]]$GitArgs, [switch]$AllowFail) {
    $r = Invoke-Git $RepoPath $GitArgs -AllowFail:$AllowFail
    if ($r.Code -ne 0) { return '' }
    $script:Utf8.GetString($r.Out).Trim()
}

function ConvertTo-NulList($Items) {
    $sb = New-Object Text.StringBuilder
    foreach ($i in $Items) { [void]$sb.Append([string]$i).Append([char]0) }
    , $script:Utf8.GetBytes($sb.ToString())
}

function New-GitCommit([string]$RepoPath, [string]$Message) {
    $null = Invoke-Git $RepoPath @('commit', '-q', '-F', '-') -InputBytes $script:Utf8.GetBytes($Message)
    Get-GitText $RepoPath @('rev-parse', 'HEAD')
}

function Add-GitPaths([string]$RepoPath, $Paths) {
    if (@($Paths).Count -eq 0) { return }
    $null = Invoke-Git $RepoPath @('add', '-A', '--pathspec-from-file=-', '--pathspec-file-nul') -InputBytes (ConvertTo-NulList $Paths)
}

# --------------------------------------------------------------------------
# Format conversion
# --------------------------------------------------------------------------

function Get-MappedPath([string]$Path) {
    # ws_objects/<dirs>/<lib>.pbl.src/<rest>  ->  <dirs>/<lib>.pbl/<rest>
    $parts = $Path.Split('/')
    $i = [Array]::IndexOf($parts, 'ws_objects')
    if ($i -lt 0) { return $null }
    for ($k = $i + 1; $k -lt $parts.Length - 1; $k++) {
        if (Test-Suffix $parts[$k] '.pbl.src') {
            $parts[$k] = $parts[$k].Substring(0, $parts[$k].Length - 4)
            $kept = New-Object System.Collections.Generic.List[string]
            for ($j = 0; $j -lt $parts.Length; $j++) { if ($j -ne $i) { $kept.Add($parts[$j]) } }
            return ($kept -join '/')
        }
    }
    $null
}

function Get-LibraryDir([string]$NewPath) {
    $parts = $NewPath.Split('/')
    for ($k = 0; $k -lt $parts.Length - 1; $k++) {
        if (Test-Suffix $parts[$k] '.pbl') { return ($parts[0..$k] -join '/') }
    }
    $null
}

function Get-PblmetaPath([string]$LibDir) {
    $name = $LibDir.Substring($LibDir.LastIndexOf('/') + 1)
    $LibDir + '/' + $name.Substring(0, $name.Length - 4) + '.pblmeta'
}

function Split-FirstLine([string]$s) {
    $n = $s.IndexOf([char]10)
    if ($n -lt 0) { return @($s, '') }
    @($s.Substring(0, $n + 1), $s.Substring($n + 1))
}

function Convert-Source([string]$Text, [string]$Path) {
    # $Text is Latin-1 (one char per byte). Returns the converted text and notes.
    # $PBExportHeader$<name>    is dropped
    # $PBExportComments$<text>  becomes //objectcomments <text>
    # as PowerBuilder 2025 R2's own conversion does.
    $utf16 = $false
    if (Test-Prefix $Text ([string][char]0xFF + [char]0xFE)) {
        $u = [Text.Encoding]::Unicode.GetString($script:L1.GetBytes($Text), 2, $Text.Length - 2)
        $Text = $script:BOM + $script:L1.GetString($script:Utf8.GetBytes($u))
        $utf16 = $true
    }
    $bom = Test-Prefix $Text $script:BOM
    $body = if ($bom) { $Text.Substring(3) } else { $Text }
    $line, $rest = Split-FirstLine $body
    if (Test-Prefix $line '$PBExportHeader$') {
        $body = $rest
        $line, $rest = Split-FirstLine $body
    }
    if (Test-Prefix $line '$PBExportComments$') {
        $body = '//objectcomments ' + $line.Substring(18) + $rest
    }
    [pscustomobject]@{
        Text   = $(if ($bom) { $script:BOM + $body } else { $body })
        Binary = $body.Contains('Start of PowerBuilder Binary Data Section')
        Utf16  = $utf16
    }
}

function Get-Eol([string]$Text) { if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" } }

function ConvertFrom-FileBytes([byte[]]$Bytes) {
    # Real text (for parsing), not Latin-1: UTF-8, falling back to Windows-1252.
    $off = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $off = 3 }
    try { $script:Utf8Strict.GetString($Bytes, $off, $Bytes.Length - $off) }
    catch { [Text.Encoding]::GetEncoding(1252).GetString($Bytes, $off, $Bytes.Length - $off) }
}

function Read-PbSave([byte[]]$Bytes) {
    # Parse a .pbw/.pbt ("Save Format v3.0") file. Values are unescaped
    # (\\ -> \); section entries are kept raw, because PowerBuilder copies
    # some of them into the .pbproj exactly as written.
    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $sections = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
    $current = $null
    foreach ($raw in ((ConvertFrom-FileBytes $Bytes) -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^@begin\s+(\w+)') {
            $current = New-Object System.Collections.Generic.List[string]
            $sections[$Matches[1]] = $current
            continue
        }
        if ($line.StartsWith('@end')) { $current = $null; continue }
        if ($null -ne $current) {
            if ($line -match '^\d+\s+"(.*)";?$') { $current.Add($Matches[1]) }
            continue
        }
        if ($line -match '^(\w+)\s+"(.*)";?$') { $values[$Matches[1]] = $Matches[2].Replace('\\', '\') }
    }
    [pscustomobject]@{ Values = $values; Sections = $sections }
}

function Get-PbValue($Parsed, [string]$Key, [string]$Default = '') {
    if ($Parsed.Values.ContainsKey($Key)) { $Parsed.Values[$Key] } else { $Default }
}

function Get-PbSection($Parsed, [string]$Name) {
    if ($Parsed.Sections.ContainsKey($Name)) { $Parsed.Sections[$Name] } else { @() }
}

function ConvertTo-XmlAttr([string]$s) {
    $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-XmlFileBytes($Lines, [string]$Eol) {
    $text = ($Lines -join $Eol) + $Eol
    , (Join-Bom $script:Utf8.GetBytes($text))
}

function Join-Bom([byte[]]$Bytes) {
    $out = New-Object byte[] ($Bytes.Length + 3)
    $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
    [Buffer]::BlockCopy($Bytes, 0, $out, 3, $Bytes.Length)
    , $out
}

function Convert-Pbw([byte[]]$Bytes) {
    $pb = Read-PbSave $Bytes
    $eol = Get-Eol $script:L1.GetString($Bytes)
    $default = Get-PbValue $pb 'DefaultTarget'
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('<?xml version="1.0" encoding="UTF-8" standalone="no" ?>')
    $out.Add('<Solution>')
    if ($default) { $out.Add('  <Projects Default="{0}">' -f (ConvertTo-XmlAttr (Set-Ext $default '.pbproj'))) }
    else { $out.Add('  <Projects>') }
    foreach ($t in (Get-PbSection $pb 'Targets')) {
        $out.Add('    <Project Path="{0}"/>' -f (ConvertTo-XmlAttr (Set-Ext $t.Replace('\\', '\').Replace('/', '\') '.pbproj')))
    }
    $out.Add('  </Projects>')
    $out.Add('</Solution>')
    New-XmlFileBytes $out $eol
}

function Convert-Pbt([byte[]]$Bytes) {
    # .pbt -> .pbproj, in the layout PowerBuilder 2025 R2's conversion writes.
    # Each entry of the target's Projects list ("<deploy>&<name>&<library>")
    # becomes a <Deploying> element, copied as written in the .pbt (its
    # library path keeps the doubled backslashes, as R2 leaves it).
    $pb = Read-PbSave $Bytes
    $eol = Get-Eol $script:L1.GetString($Bytes)
    $libs = @((Get-PbValue $pb 'LibList').Split(';') | Where-Object { $_ })
    $first = if ($libs.Count) { $libs[0] } else { '' }
    $applib = Get-PbValue $pb 'applib' $first
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('<?xml version="1.0" encoding="UTF-8" standalone="no" ?>')
    $out.Add('<Project>')
    $out.Add('  <Type Name="{0}"/>' -f (ConvertTo-XmlAttr (Get-PbValue $pb 'type' 'pb')))
    $out.Add('  <Application Name="{0}"/>' -f (ConvertTo-XmlAttr (Get-PbValue $pb 'appname')))
    $out.Add('  <Libraries AppEntry="{0}">' -f (ConvertTo-XmlAttr $applib))
    foreach ($l in $libs) { $out.Add('    <Library Path="{0}"/>' -f (ConvertTo-XmlAttr $l)) }
    $out.Add('  </Libraries>')
    $deploys = @(Get-PbSection $pb 'Projects' | ForEach-Object { , $_.Split([char[]]@('&'), 3) } |
                 Where-Object { $_.Length -eq 3 })
    if ($deploys.Count) {
        $out.Add('  <Deployings>')
        foreach ($d in $deploys) {
            $line = '    <Deploying Deploy="{0}" Library="{1}" Name="{2}"/>' -f (ConvertTo-XmlAttr $d[0]), (ConvertTo-XmlAttr $d[2]), (ConvertTo-XmlAttr $d[1])
            $out.Add($line)
        }
        $out.Add('  </Deployings>')
    }
    $out.Add('</Project>')
    New-XmlFileBytes $out $eol
}

function New-Pblmeta([string]$Eol = "`r`n") {
    # No final newline, as the IDE writes it.
    $text = '{' + $Eol + '    "version": "' + $script:PblVersion + '",' + $Eol +
            '    "comment": "' + $script:PblComment + '"' + $Eol + '}'
    , (Join-Bom $script:Utf8.GetBytes($text))
}

function Test-Gitignore([string]$Path) {
    ($Path -ceq '.gitignore') -or $Path.EndsWith('/.gitignore', $script:Ord)
}

function Repair-Gitignore([string]$Text) {
    # A Workspace-mode .gitignore usually ignores the binary libraries with a
    # pattern such as *.pbl. In Solution mode that pattern matches the .pbl
    # source folders, so git would ignore every object added to them. For each
    # such pattern, add a negation that re-includes the folders (a trailing /
    # matches only directories): *.pbl  ->  !*.pbl/
    # Latin-1 string in and out; returns $Text unchanged if nothing is needed.
    $body = if (Test-Prefix $Text $script:BOM) { $Text.Substring(3) } else { $Text }
    $ws = [char[]]" `t`r`n`v`f"
    $lines = @($body.Split("`n") | ForEach-Object { $_.Trim($ws) })
    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($l in $lines) { [void]$have.Add($l) }
    $add = New-Object System.Collections.Generic.List[string]
    foreach ($p in $lines) {
        if (-not $p -or (Test-Prefix $p '#') -or (Test-Prefix $p '!') -or $p.EndsWith('/', $script:Ord)) { continue }
        if (Test-Suffix $p '.pbl') {
            $neg = '!' + $p + '/'
            if (-not $have.Contains($neg) -and -not $add.Contains($neg)) { $add.Add($neg) }
        }
    }
    if ($add.Count -eq 0) { return $Text }
    if (-not $have.Contains($script:GitignoreNote)) { $add.Insert(0, $script:GitignoreNote) }
    $nl = Get-Eol $Text
    $sep = if ($body -and $Text[-1] -ne "`n" -and $Text[-1] -ne "`r") { $nl } else { '' }
    $Text + $sep + ($add -join $nl) + $nl
}

# --------------------------------------------------------------------------
# -IdeOutput overlay
# --------------------------------------------------------------------------

function ConvertTo-RelPath([string]$Path) {
    # Normalize a relative path: forward slashes, no "." or ".." segments.
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($seg in $Path.Replace('\', '/').Split('/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; continue }
        $stack.Add($seg)
    }
    $stack -join '/'
}

function Resolve-Case([string]$Root, [string]$Rel, $Cache) {
    # Spell a relative path the way it exists below $Root. PowerBuilder paths
    # are case-insensitive (a .pbsln may say pbl\x.pbproj for a PBL folder),
    # but git pathspecs and non-Windows file systems are not. Components that
    # don't exist are kept as given. $Cache: folder -> names in it.
    $out = New-Object System.Collections.Generic.List[string]
    $cur = $Root
    foreach ($part in $Rel.Split('/')) {
        if (-not $Cache.ContainsKey($cur)) {
            $names = New-Object System.Collections.Generic.List[string]
            if ([IO.Directory]::Exists($cur)) {
                foreach ($e in [IO.Directory]::GetFileSystemEntries($cur)) { $names.Add([IO.Path]::GetFileName($e)) }
            }
            $Cache[$cur] = $names
        }
        $hit = $part
        if (-not $Cache[$cur].Contains($part)) {
            foreach ($n in $Cache[$cur]) {
                if ($n.ToLowerInvariant() -ceq $part.ToLowerInvariant()) { $hit = $n; break }
            }
        }
        $out.Add($hit)
        $cur = [IO.Path]::Combine($cur, $hit)
    }
    $out -join '/'
}

function Get-SolutionFiles([string]$IdeDir) {
    # The .pbsln at the folder's root, the .pbproj files it lists, and every
    # file in the library folders those projects use. Build output (which also
    # contains .pbl folders) is not part of it. Paths are spelled as on disk.
    $cache = @{}
    $slns = @([IO.Directory]::GetFiles($IdeDir) | Where-Object { Test-Suffix $_ '.pbsln' })
    if ($slns.Count -eq 0) { Stop-Migration "-IdeOutput $IdeDir has no .pbsln file at its root." }
    $files = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $libdirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($sln in $slns) {
        [void]$files.Add([IO.Path]::GetFileName($sln))
        $text = ConvertFrom-FileBytes ([IO.File]::ReadAllBytes($sln))
        foreach ($m in [regex]::Matches($text, '<Project\s+Path="([^"]+)"')) {
            $proj = Resolve-Case $IdeDir (ConvertTo-RelPath $m.Groups[1].Value) $cache
            $full = [IO.Path]::Combine($IdeDir, $proj)
            if (-not [IO.File]::Exists($full)) { continue }
            [void]$files.Add($proj)
            $ptext = ConvertFrom-FileBytes ([IO.File]::ReadAllBytes($full))
            $base = [IO.Path]::GetDirectoryName($proj)
            foreach ($lm in [regex]::Matches($ptext, '(?:Library Path|AppEntry)="([^"]+)"')) {
                [void]$libdirs.Add((Resolve-Case $IdeDir (ConvertTo-RelPath ($base + '/' + $lm.Groups[1].Value)) $cache))
            }
        }
    }
    $root = [IO.Path]::GetFullPath($IdeDir).TrimEnd('\', '/')
    foreach ($d in $libdirs) {
        $full = [IO.Path]::Combine($root, $d)
        if (-not [IO.Directory]::Exists($full)) { continue }
        foreach ($f in [IO.Directory]::GetFiles($full, '*', [IO.SearchOption]::AllDirectories)) {
            [void]$files.Add($f.Substring($root.Length + 1).Replace('\', '/'))
        }
    }
    , @($files)
}

function Copy-IdeOutput([string]$RepoPath, [string]$IdeDir, $MappedLibDirs) {
    # Copies each IDE file to the spelling the repository already uses for it.
    # Returns .Changed (paths written), .Leftovers (files in .pbl folders the
    # IDE did not write) and .Skipped (IDE files the .gitignore excludes).
    $cache = @{}
    $candidates = Get-SolutionFiles $IdeDir
    $targets = @($candidates | ForEach-Object { , @($_, (Resolve-Case $RepoPath $_ $cache)) })
    $r = Invoke-Git $RepoPath @('check-ignore', '--no-index', '-z', '--stdin') -InputBytes (ConvertTo-NulList @($targets | ForEach-Object { $_[1] })) -AllowFail
    $ignored = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($p in $script:Utf8.GetString($r.Out).Split([char]0)) { if ($p) { [void]$ignored.Add($p) } }
    $changed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $targets) {
        $src, $rel = $t[0], $t[1]
        if ($ignored.Contains($rel)) { $skipped.Add($rel); continue }
        [void]$seen.Add($rel)
        $dst = [IO.Path]::Combine($RepoPath, $rel)
        $new = [IO.File]::ReadAllBytes([IO.Path]::Combine($IdeDir, $src))
        if ([IO.File]::Exists($dst)) {
            $old = [IO.File]::ReadAllBytes($dst)
            if ($old.Length -eq $new.Length -and [Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($new)) { continue }
        }
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
        [IO.File]::WriteAllBytes($dst, $new)
        $changed.Add($rel)
    }
    $leftovers = New-Object System.Collections.Generic.List[string]
    foreach ($libdir in ($MappedLibDirs | Sort-Object)) {
        $d = [IO.Path]::Combine($RepoPath, $libdir)
        if (-not [IO.Directory]::Exists($d)) { continue }
        foreach ($f in [IO.Directory]::GetFileSystemEntries($d)) {
            $rel = $libdir + '/' + [IO.Path]::GetFileName($f)
            if (-not $seen.Contains($rel)) { $leftovers.Add($rel) }
        }
    }
    [pscustomobject]@{ Changed = $changed; Leftovers = $leftovers; Skipped = $skipped }
}

function Write-Report($Unmapped, $BinaryObjs, [int]$Utf16Count, $Leftovers, $Skipped = @()) {
    # Drop $null entries: "if (...) { @() }" yields $null, and @($null).Count is 1.
    $Unmapped = @($Unmapped | Where-Object { $_ })
    $BinaryObjs = @($BinaryObjs | Where-Object { $_ })
    $Leftovers = @($Leftovers | Where-Object { $_ })
    $Skipped = @($Skipped | Where-Object { $_ })
    if (@($Unmapped).Count) {
        Write-Host "`nFiles under ws_objects outside any .pbl.src folder were left as they are:"
        @($Unmapped) | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    }
    if (@($BinaryObjs).Count) {
        Write-Host ("`nThese objects carry an inline binary data section (OLE controls). The" +
                    "`nIDE stores that data in a separate .bin file in Solution mode; run with" +
                    "`n-IdeOutput, or open and save each object in the IDE:")
        @($BinaryObjs) | ForEach-Object { Write-Host "  $_" }
    }
    if ($Utf16Count) { Write-Host "`n$Utf16Count objects were UTF-16 and are now UTF-8 with a BOM." }
    if (@($Leftovers).Count) {
        Write-Host "`nFiles in .pbl folders that the IDE output does not contain (kept):"
        @($Leftovers) | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if (@($Leftovers).Count -gt 20) { Write-Host ("  ... and {0} more" -f (@($Leftovers).Count - 20)) }
    }
    if (@($Skipped).Count) {
        Write-Host "`nIDE output files skipped because the repository's .gitignore excludes them:"
        @($Skipped) | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if (@($Skipped).Count -gt 20) { Write-Host ("  ... and {0} more" -f (@($Skipped).Count - 20)) }
    }
}

# --------------------------------------------------------------------------
# inplace mode
# --------------------------------------------------------------------------

function Remove-EmptyDirs([string]$RepoPath, $Dirs) {
    foreach ($d in ($Dirs | Sort-Object { $_.Length } -Descending)) {
        while ($d) {
            $full = [IO.Path]::Combine($RepoPath, $d)
            if ([IO.Directory]::Exists($full) -and @([IO.Directory]::GetFileSystemEntries($full)).Count -eq 0) {
                [IO.Directory]::Delete($full)
                $i = $d.LastIndexOf('/')
                $d = if ($i -gt 0) { $d.Substring(0, $i) } else { '' }
            } else { break }
        }
    }
}

function Write-RepoFile([string]$RepoPath, [string]$Rel, [byte[]]$Bytes) {
    $full = [IO.Path]::Combine($RepoPath, $Rel)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllBytes($full, $Bytes)
}

function Invoke-Inplace {
    $repoPath = Get-GitText (Resolve-UserPath $Repo) @('rev-parse', '--show-toplevel')
    if (Get-GitText $repoPath @('status', '--porcelain', '--untracked-files=no')) {
        Stop-Migration 'The repository has uncommitted changes. Commit or stash them first.'
    }
    if ((Invoke-Git $repoPath @('rev-parse', '--verify', '-q', "refs/heads/$Branch") -AllowFail).Code -eq 0) {
        Stop-Migration "Branch $Branch already exists."
    }

    # Index entries: path -> (mode, sha)
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
    foreach ($rec in $script:Utf8.GetString((Invoke-Git $repoPath @('ls-files', '-s', '-z')).Out).Split([char]0)) {
        if (-not $rec) { continue }
        $tab = $rec.IndexOf("`t")
        $meta = $rec.Substring(0, $tab).Split(' ')
        $entries[$rec.Substring($tab + 1)] = @($meta[0], $meta[1])
    }
    $lowerEntries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $entries.Keys) { $lowerEntries[$p] = $p }

    $mapping = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
    $unmapped = New-Object System.Collections.Generic.List[string]
    foreach ($p in $entries.Keys) {
        $n = Get-MappedPath $p
        if ($n) { $mapping[$p] = $n }
        elseif (('/' + $p).Contains('/ws_objects/')) { $unmapped.Add($p) }
    }
    if ($mapping.Count -eq 0) {
        Stop-Migration 'No ws_objects/<lib>.pbl.src files found: is this a Workspace-mode repository?'
    }
    $libdirs = @($mapping.Values | ForEach-Object { Get-LibraryDir $_ } | Sort-Object -Unique)

    $clash = @($mapping.Values | Where-Object { $lowerEntries.ContainsKey($_) })
    if ($clash.Count) {
        Stop-Migration ("These target paths are already tracked:`n  " + (($clash | Select-Object -First 20) -join "`n  "))
    }
    $trackedPbls = @($libdirs | Where-Object { $lowerEntries.ContainsKey($_) } | ForEach-Object { $lowerEntries[$_] })
    $localPbls = @($libdirs | Where-Object {
        [IO.File]::Exists([IO.Path]::Combine($repoPath, $_)) -and -not $lowerEntries.ContainsKey($_) })
    if ($localPbls.Count -and -not $MovePblsTo) {
        Stop-Migration ("These untracked .pbl files sit where the new .pbl folders go:`n  " +
                        ($localPbls -join "`n  ") +
                        "`nPass -MovePblsTo <folder outside the repository> to move them aside.")
    }

    Write-Host ("Branch {0} from {1}" -f $Branch, (Get-GitText $repoPath @('rev-parse', '--short', 'HEAD')))
    $null = Invoke-Git $repoPath @('switch', '-q', '-c', $Branch)

    # ---- commit 1: pure renames -------------------------------------------
    $moveTo = Resolve-UserPath $MovePblsTo
    foreach ($d in $localPbls) {
        $dst = [IO.Path]::GetFullPath([IO.Path]::Combine($moveTo, $d))
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
        [IO.File]::Move([IO.Path]::Combine($repoPath, $d), $dst)
        Write-Host "Moved local $d to $dst"
    }
    if ($trackedPbls.Count) { $null = Invoke-Git $repoPath (@('rm', '-q', '--') + $trackedPbls) }

    $info = New-Object Text.StringBuilder
    $zeros = '0' * 40
    foreach ($kv in $mapping.GetEnumerator()) {
        $mode, $sha = $entries[$kv.Key]
        $src = [IO.Path]::Combine($repoPath, $kv.Key)
        $dst = [IO.Path]::Combine($repoPath, $kv.Value)
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
        [IO.File]::Move($src, $dst)
        [void]$info.Append("0 $($zeros.Substring(0, $sha.Length))`t$($kv.Key)`n")
        [void]$info.Append("$mode $sha`t$($kv.Value)`n")
    }
    $null = Invoke-Git $repoPath @('update-index', '--index-info') -InputBytes $script:Utf8.GetBytes($info.ToString())
    Remove-EmptyDirs $repoPath @($mapping.Keys | ForEach-Object { $_.Substring(0, $_.LastIndexOf('/')) } | Sort-Object -Unique)
    $msg1 = if ($MessageRename) { $MessageRename } else {
        "Move the source from ws_objects into .pbl folders (Solution mode)`n`n" +
        "A pure rename: no file content changes, so git follows each file's`n" +
        "history across the move. The next commit converts the formats." }
    $sha1 = New-GitCommit $repoPath $msg1

    # ---- commit 2: conversion ---------------------------------------------
    $touched = New-Object System.Collections.Generic.List[string]
    $binaryObjs = New-Object System.Collections.Generic.List[string]
    $utf16 = 0
    foreach ($new in ($mapping.Values | Sort-Object)) {
        if ($script:SourceExts -notcontains (Get-Ext $new)) { continue }
        $full = [IO.Path]::Combine($repoPath, $new)
        $text = $script:L1.GetString([IO.File]::ReadAllBytes($full))
        $c = Convert-Source $text $new
        if ($c.Binary) { $binaryObjs.Add($new) }
        if ($c.Utf16) { $utf16++ }
        if ($c.Text -cne $text) {
            [IO.File]::WriteAllBytes($full, $script:L1.GetBytes($c.Text))
            $touched.Add($new)
        }
    }

    $sampleEol = "`r`n"
    foreach ($p in ($entries.Keys | Sort-Object)) {
        if (Test-Suffix $p '.pbw') {
            $bytes = [IO.File]::ReadAllBytes([IO.Path]::Combine($repoPath, $p))
            $sampleEol = Get-Eol $script:L1.GetString($bytes)
            $out = Set-Ext $p '.pbsln'
            Write-RepoFile $repoPath $out (Convert-Pbw $bytes)
            $null = Invoke-Git $repoPath @('rm', '-q', '--', $p)
            $touched.Add($out)
        } elseif (Test-Suffix $p '.pbt') {
            $bytes = [IO.File]::ReadAllBytes([IO.Path]::Combine($repoPath, $p))
            $out = Set-Ext $p '.pbproj'
            Write-RepoFile $repoPath $out (Convert-Pbt $bytes)
            $null = Invoke-Git $repoPath @('rm', '-q', '--', $p)
            $touched.Add($out)
        } elseif (Test-Gitignore $p) {
            $text = $script:L1.GetString([IO.File]::ReadAllBytes([IO.Path]::Combine($repoPath, $p)))
            $fixed = Repair-Gitignore $text
            if ($fixed -cne $text) {
                Write-RepoFile $repoPath $p $script:L1.GetBytes($fixed)
                $touched.Add($p)
            }
        }
    }
    foreach ($d in $libdirs) {
        $meta = Get-PblmetaPath $d
        if (-not [IO.File]::Exists([IO.Path]::Combine($repoPath, $meta))) {
            Write-RepoFile $repoPath $meta (New-Pblmeta $sampleEol)
            $touched.Add($meta)
        }
    }
    Add-GitPaths $repoPath $touched
    $msg2 = if ($MessageConvert) { $MessageConvert } else {
        "Convert to PowerBuilder Solution format`n`n" +
        "Export headers become //objectcomments lines, the workspace and`n" +
        "target files become a .pbsln and .pbproj files, and each library`n" +
        "folder gets a .pblmeta file." }
    $sha2 = New-GitCommit $repoPath $msg2

    # ---- optional commit 3: the IDE's own output --------------------------
    $sha3 = $null
    $leftovers = @()
    $skipped = @()
    if ($IdeOutput) {
        $ide = Copy-IdeOutput $repoPath (Resolve-UserPath $IdeOutput) $libdirs
        $leftovers = $ide.Leftovers
        $skipped = $ide.Skipped
        Add-GitPaths $repoPath $ide.Changed
        if (Get-GitText $repoPath @('diff', '--cached', '--name-only')) {
            $sha3 = New-GitCommit $repoPath "Apply PowerBuilder's own Solution migration output"
        }
    }

    # ---- report ------------------------------------------------------------
    $renames = (Get-GitText $repoPath @('diff', '--name-status', '-M', '--find-renames=100%', "$sha1~1", $sha1)) -split "`n"
    $exact = @($renames | Where-Object { $_.StartsWith('R100') }).Count
    Write-Host ''
    Write-Host ("Commit 1 (renames):    {0}  {1} files moved, {2} detected by git as exact renames" -f $sha1.Substring(0, 10), $mapping.Count, $exact)
    Write-Host ("Commit 2 (conversion): {0}  {1} files written" -f $sha2.Substring(0, 10), $touched.Count)
    if ($sha3) { Write-Host ("Commit 3 (IDE output): {0}" -f $sha3.Substring(0, 10)) }
    $bin = if ($IdeOutput) { @() } else { $binaryObjs }
    Write-Report $unmapped $bin $utf16 $leftovers $skipped
    $example = @($mapping.Values | Sort-Object)[0]
    Write-Host "`nNothing was pushed. Review with:  git log --stat -3   and, for any object,"
    Write-Host "  git log --follow -- `"$example`""
}

# --------------------------------------------------------------------------
# rewrite mode
# --------------------------------------------------------------------------

# Reads lines and counted blocks from a byte stream, as Latin-1 strings.
class ByteReader {
    [IO.Stream]$Stream
    [byte[]]$Buf
    [int]$Pos
    [int]$Len
    [Text.Encoding]$Enc

    ByteReader([IO.Stream]$s) {
        $this.Stream = $s
        $this.Buf = New-Object byte[] 65536
        $this.Pos = 0
        $this.Len = 0
        $this.Enc = [Text.Encoding]::GetEncoding(28591)
    }

    [bool] Fill() {
        if ($this.Pos -lt $this.Len) { return $true }
        $this.Pos = 0
        $this.Len = $this.Stream.Read($this.Buf, 0, $this.Buf.Length)
        if ($this.Len -le 0) { $this.Len = 0; return $false }
        return $true
    }

    # One line including its "\n"; "" at end of stream.
    [string] ReadLine() {
        $sb = New-Object Text.StringBuilder
        while ($this.Fill()) {
            $i = [Array]::IndexOf($this.Buf, [byte]10, $this.Pos, $this.Len - $this.Pos)
            if ($i -ge 0) {
                [void]$sb.Append($this.Enc.GetString($this.Buf, $this.Pos, $i - $this.Pos + 1))
                $this.Pos = $i + 1
                return $sb.ToString()
            }
            [void]$sb.Append($this.Enc.GetString($this.Buf, $this.Pos, $this.Len - $this.Pos))
            $this.Pos = $this.Len
        }
        return $sb.ToString()
    }

    [string] Read([int]$n) {
        $sb = New-Object Text.StringBuilder $n
        while ($n -gt 0 -and $this.Fill()) {
            $take = [Math]::Min($n, $this.Len - $this.Pos)
            [void]$sb.Append($this.Enc.GetString($this.Buf, $this.Pos, $take))
            $this.Pos += $take
            $n -= $take
        }
        return $sb.ToString()
    }
}

function ConvertFrom-GitQuoted([string]$p) {
    # Undo git's C-style path quoting (Latin-1 in, Latin-1 out).
    if (-not $p.StartsWith('"')) { return $p }
    $s = $p.Substring(1, $p.Length - 2)
    $sb = New-Object Text.StringBuilder
    $escChars = 'nt"\abfrv'
    $escCodes = @(10, 9, 34, 92, 7, 8, 12, 13, 11)
    $i = 0
    while ($i -lt $s.Length) {
        if ($s[$i] -ceq [char]'\') {
            $k = $escChars.IndexOf($s[$i + 1])
            if ($k -ge 0) { [void]$sb.Append([char]$escCodes[$k]); $i += 2 }
            else { [void]$sb.Append([char][Convert]::ToInt32($s.Substring($i + 1, 3), 8)); $i += 4 }
        } else {
            [void]$sb.Append($s[$i]); $i++
        }
    }
    $sb.ToString()
}

function ConvertTo-GitQuoted([string]$p) {
    if ($p.Contains('"') -or $p.Contains("`n") -or $p.Contains('\') -or $p.StartsWith(' ')) {
        return '"' + $p.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n') + '"'
    }
    $p
}

# Latin-1 path from the stream <-> real path
function ConvertFrom-L1Path([string]$p) { $script:Utf8.GetString($script:L1.GetBytes($p)) }
function ConvertTo-L1Path([string]$p) { $script:L1.GetString($script:Utf8.GetBytes($p)) }

function Read-Blob($Cat, [string]$Sha) {
    $Cat.In.Write($script:L1.GetBytes("$Sha`n"), 0, $Sha.Length + 1)
    $Cat.In.Flush()
    $header = $Cat.Reader.ReadLine().Split(' ')
    $data = $Cat.Reader.Read([int]$header[2])
    $null = $Cat.Reader.Read(1)
    $data
}

function Format-Inline([string]$L1Path, [string]$L1Data) {
    "M 100644 inline $(ConvertTo-GitQuoted $L1Path)`ndata $($L1Data.Length)`n$L1Data`n"
}

function Convert-Op([string]$Line, $Cat, $Stats, $BinaryObjs, $LibDirs) {
    # Rewrite one fast-export file operation (Latin-1 in, Latin-1 out).
    if (Test-Prefix $Line 'M ') {
        $bits = $Line.Substring(2).TrimEnd("`n").Split(@(' '), 3, [StringSplitOptions]::None)
        $mode, $ref = $bits[0], $bits[1]
        if ($mode -eq '160000') { return $Line }
        $p = ConvertFrom-GitQuoted $bits[2]
        $new = Get-MappedPath $p
        if ($new) {
            if ($script:SourceExts -contains (Get-Ext $new)) {
                $c = Convert-Source (Read-Blob $Cat $ref) $new
                if ($c.Binary) { [void]$BinaryObjs.Add($new) }
                $LibDirs[(Get-LibraryDir $new)] = Get-Eol $c.Text
                $Stats.converted++
                return "M $mode inline $(ConvertTo-GitQuoted $new)`ndata $($c.Text.Length)`n$($c.Text)`n"
            }
            $Stats.renamed++
            return "M $mode $ref $(ConvertTo-GitQuoted $new)`n"
        }
        if (Test-Suffix $p '.pbl') { $Stats.pbl++; return '' }
        if ((Test-Suffix $p '.pbt') -or (Test-Suffix $p '.pbw')) {
            $bytes = $script:L1.GetBytes((Read-Blob $Cat $ref))
            if (Test-Suffix $p '.pbt') { $Stats.pbt++; $out = Convert-Pbt $bytes; $ext = '.pbproj' }
            else { $Stats.pbw++; $out = Convert-Pbw $bytes; $ext = '.pbsln' }
            return (Format-Inline (Set-Ext $p $ext) $script:L1.GetString($out))
        }
        if (Test-Gitignore $p) {
            $text = Read-Blob $Cat $ref
            $fixed = Repair-Gitignore $text
            if ($fixed -cne $text) {
                $Stats.gitignore++
                return "M $mode inline $(ConvertTo-GitQuoted $p)`ndata $($fixed.Length)`n$fixed`n"
            }
        }
        return $Line
    }
    if (Test-Prefix $Line 'D ') {
        $p = ConvertFrom-GitQuoted $Line.Substring(2).TrimEnd("`n")
        $new = Get-MappedPath $p
        if ($new) { return "D $(ConvertTo-GitQuoted $new)`n" }
        if (Test-Suffix $p '.pbl') { return '' }
        if (Test-Suffix $p '.pbt') { return "D $(ConvertTo-GitQuoted (Set-Ext $p '.pbproj'))`n" }
        if (Test-Suffix $p '.pbw') { return "D $(ConvertTo-GitQuoted (Set-Ext $p '.pbsln'))`n" }
        return $Line
    }
    if ((Test-Prefix $Line 'R ') -or (Test-Prefix $Line 'C ')) {
        Stop-Migration "Unexpected rename/copy in fast-export output: $Line"
    }
    $Line    # deleteall, N (notes), etc.
}

function Invoke-Rewrite {
    if (-not $Output) { Stop-Migration 'rewrite needs -Output <new, empty folder>.' }
    $src = Get-GitText (Resolve-UserPath $Repo) @('rev-parse', '--show-toplevel')
    $out = Resolve-UserPath $Output
    if ([IO.Directory]::Exists($out) -and @([IO.Directory]::GetFileSystemEntries($out)).Count) {
        Stop-Migration "$out exists and is not empty."
    }
    $null = [IO.Directory]::CreateDirectory($out)
    $null = Invoke-Git $null @('init', '-q', $out)
    $objects = Get-GitText $src @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $alt = [IO.Path]::Combine($out, '.git', 'objects', 'info', 'alternates')
    [IO.File]::WriteAllText($alt, ($objects + '/objects').Replace('\', '/') + "`n", $script:Utf8)

    $marks = [IO.Path]::Combine($out, '.git', 'migrator-marks')
    $exp = Start-Git @('-C', $src, 'fast-export', '--branches', '--tags', '--no-data',
                       '--signed-tags=strip', '--tag-of-filtered-object=rewrite',
                       '--reencode=no', '--show-original-ids') $false $true $false
    $imp = Start-Git @('-C', $out, 'fast-import', '--quiet', "--export-marks=$marks") $true $false $false
    $catP = Start-Git @('-C', $src, 'cat-file', '--batch') $true $true $false
    $cat = [pscustomobject]@{ In = $catP.StandardInput.BaseStream; Reader = [ByteReader]::new($catP.StandardOutput.BaseStream) }

    $r = [ByteReader]::new($exp.StandardOutput.BaseStream)
    $w = New-Object IO.BufferedStream($imp.StandardInput.BaseStream, 1048576)
    $L1 = $script:L1
    $stats = @{ commits = 0; converted = 0; renamed = 0; pbl = 0; pbt = 0; pbw = 0; gitignore = 0 }
    $binaryObjs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $origIds = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)

    while ($true) {
        $line = $r.ReadLine()
        if ($line -eq '') { break }
        if (Test-Prefix $line 'commit ') {
            $head = New-Object Text.StringBuilder
            [void]$head.Append($line)
            $mark = $null
            while ($true) {
                $line = $r.ReadLine()
                if (Test-Prefix $line 'data ') {
                    [void]$head.Append($line).Append($r.Read([int]$line.Substring(5).Trim()))
                } elseif (Test-Prefix $line 'mark ') {
                    $mark = $line.Substring(5).Trim()
                    [void]$head.Append($line)
                } elseif (Test-Prefix $line 'original-oid ') {
                    if ($mark) { $origIds[$mark] = $line.Substring(13).Trim() }
                    [void]$head.Append($line)
                } elseif ((Test-Prefix $line 'author ') -or (Test-Prefix $line 'committer ') -or
                          (Test-Prefix $line 'encoding ') -or (Test-Prefix $line 'from ') -or
                          (Test-Prefix $line 'merge ')) {
                    [void]$head.Append($line)
                } else { break }
            }
            # file operations until a blank line
            $libdirs = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
            $ops = New-Object Text.StringBuilder
            while ($line -ne "`n" -and $line -ne '') {
                [void]$ops.Append((Convert-Op $line $cat $stats $binaryObjs $libdirs))
                $line = $r.ReadLine()
            }
            foreach ($kv in $libdirs.GetEnumerator()) {
                $meta = $L1.GetString((New-Pblmeta $kv.Value))
                [void]$ops.Append((Format-Inline (Get-PblmetaPath $kv.Key) $meta))
            }
            $bytes = $L1.GetBytes($head.ToString() + $ops.ToString() + "`n")
            $w.Write($bytes, 0, $bytes.Length)
            $stats.commits++
        } elseif (Test-Prefix $line 'data ') {
            $bytes = $L1.GetBytes($line + $r.Read([int]$line.Substring(5).Trim()))
            $w.Write($bytes, 0, $bytes.Length)
        } else {
            $bytes = $L1.GetBytes($line)
            $w.Write($bytes, 0, $bytes.Length)
        }
    }
    $cat.In.Close(); $catP.WaitForExit()
    $w.Flush(); $w.Close()
    $exp.WaitForExit(); $imp.WaitForExit()
    if ($exp.ExitCode -ne 0 -or $imp.ExitCode -ne 0) { Stop-Migration 'fast-export / fast-import failed.' }

    # Make the new repository self-contained, then drop the alternates link.
    $null = Invoke-Git $out @('repack', '-a', '-d', '-q')
    [IO.File]::Delete($alt)

    # Commit map: old sha -> new sha
    $newIds = @{}
    foreach ($l in [IO.File]::ReadAllLines($marks)) { $m, $sha = $l.Split(' '); $newIds[$m] = $sha }
    $mapFile = [IO.Path]::Combine($out, '.git', 'migrator-commit-map.txt')
    $map = New-Object Text.StringBuilder
    foreach ($kv in $origIds.GetEnumerator()) {
        if ($newIds.ContainsKey($kv.Key)) { [void]$map.Append("$($kv.Value) $($newIds[$kv.Key])`n") }
    }
    [IO.File]::WriteAllText($mapFile, $map.ToString(), $script:Utf8)
    [IO.File]::Delete($marks)

    # Check out the branch the source repository had checked out.
    $headRef = Get-GitText $src @('symbolic-ref', '-q', 'HEAD') -AllowFail
    if (-not $headRef) { $headRef = 'refs/heads/main' }
    if ((Invoke-Git $out @('rev-parse', '--verify', '-q', $headRef) -AllowFail).Code -eq 0) {
        $null = Invoke-Git $out @('symbolic-ref', 'HEAD', $headRef)
        $null = Invoke-Git $out @('reset', '-q', '--hard')
    }
    $null = Invoke-Git $out @('fsck', '--connectivity-only', '--no-progress')

    Write-Host ("Rewrote {0} commits into {1} (checked out {2})" -f $stats.commits, $out, $headRef)
    Write-Host ("  {0} object versions converted, {1} renamed only, {2} .pbl binaries dropped, {3} .pbt and {4} .pbw converted" -f
                $stats.converted, $stats.renamed, $stats.pbl, $stats.pbt, $stats.pbw)
    if ($stats.gitignore) { Write-Host "  $($stats.gitignore) .gitignore versions now re-include the .pbl folders" }
    Write-Host "  Old -> new commit hashes: $mapFile"

    if ($IdeOutput) {
        $libdirs = @((Get-GitText $out @('ls-files')) -split "`n" | ForEach-Object { Get-LibraryDir $_ } |
                     Where-Object { $_ } | Sort-Object -Unique)
        $ide = Copy-IdeOutput $out (Resolve-UserPath $IdeOutput) $libdirs
        $leftovers = $ide.Leftovers
        Add-GitPaths $out $ide.Changed
        if (Get-GitText $out @('diff', '--cached', '--name-only')) {
            $sha = New-GitCommit $out "Apply PowerBuilder's own Solution migration output"
            Write-Host ("  Added the IDE output as {0}" -f $sha.Substring(0, 10))
        }
        Write-Report @() @() 0 $leftovers $ide.Skipped
    } else {
        $still = @($binaryObjs | Sort-Object | Where-Object {
            [IO.File]::Exists([IO.Path]::Combine($out, (ConvertFrom-L1Path $_))) } |
            ForEach-Object { ConvertFrom-L1Path $_ })
        Write-Report @() $still 0 @()
    }
    Write-Host "`nThe source repository was only read. Nothing was pushed."
}

# --------------------------------------------------------------------------

if ($IdeOutput -and -not [IO.Directory]::Exists((Resolve-UserPath $IdeOutput))) {
    Stop-Migration "-IdeOutput $IdeOutput is not a folder."
}
if ($Mode -eq 'inplace') { Invoke-Inplace } else { Invoke-Rewrite }
