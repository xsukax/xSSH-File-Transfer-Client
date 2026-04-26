#Requires -Version 5.1
<#
.SYNOPSIS
    xSSH File Transfer Client v1.0
.NOTES
    Author  : xsukax
    License : GNU General Public License v3.0

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU General Public License for more details:
    https://www.gnu.org/licenses/gpl-3.0.html
#>

# ==================================================================
#  Bootstrap
# ==================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "The Posh-SSH module is required for SSH/SFTP operations.`nInstall it now from PowerShell Gallery?",
        "xSSH - Missing Dependency",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        Install-Module Posh-SSH -Scope CurrentUser -Force -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show("Install failed:`n$msg", "Error", 'OK', 'Error')
        exit 1
    }
}
Import-Module Posh-SSH -ErrorAction Stop

# ==================================================================
#  Global State
# ==================================================================
$script:SSH_S      = $null
$script:SFTP_S     = $null
$script:Connected  = $false
$script:RemotePath = "/"
$script:LocalPath  = [System.Environment]::GetFolderPath("Desktop")

# ==================================================================
#  Theme  (GitHub Light)
# ==================================================================
$gh = @{
    Bg     = [System.Drawing.Color]::FromArgb(255, 255, 255)
    Canvas = [System.Drawing.Color]::FromArgb(246, 248, 250)
    Border = [System.Drawing.Color]::FromArgb(208, 215, 222)
    Accent = [System.Drawing.Color]::FromArgb(9,   105, 218)
    Text   = [System.Drawing.Color]::FromArgb(31,  35,  40)
    Muted  = [System.Drawing.Color]::FromArgb(87,  96,  106)
    Green  = [System.Drawing.Color]::FromArgb(31,  136, 61)
    Red    = [System.Drawing.Color]::FromArgb(207, 34,  46)
    White  = [System.Drawing.Color]::White
}
$f9  = New-Object System.Drawing.Font("Segoe UI", 9)
$f9b = New-Object System.Drawing.Font("Segoe UI", 9,  [System.Drawing.FontStyle]::Bold)
$f9m = New-Object System.Drawing.Font("Consolas", 9)

# ==================================================================
#  Utility Helpers
# ==================================================================
function Set-Status {
    param([string]$Msg, [string]$Level = "Info")
    $script:lblStat.Text = $Msg
    $script:lblStat.ForeColor = switch ($Level) {
        "Ok"  { $gh.Green }
        "Err" { $gh.Red   }
        default { $gh.Muted }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Fmt-Size {
    param([long]$b)
    if ($b -lt 1KB) { return "$b B" }
    if ($b -lt 1MB) { return ("{0:N1} KB" -f ($b / 1KB)) }
    if ($b -lt 1GB) { return ("{0:N1} MB" -f ($b / 1MB)) }
    return ("{0:N2} GB" -f ($b / 1GB))
}

function Esc { param([string]$p); return $p.Replace("'", "'\''") }

function Join-Remote {
    param([string]$base, [string]$name)
    return ($base.TrimEnd('/') + "/" + $name)
}

function Parent-Remote {
    param([string]$p)
    $p = $p.TrimEnd('/')
    if ($p -eq "" -or -not $p.Contains('/')) { return "/" }
    $idx = $p.LastIndexOf('/')
    if ($idx -le 0) { return "/" }
    return $p.Substring(0, $idx)
}

function New-Btn {
    param([string]$t, [int]$w = 100, [bool]$primary = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $t
    $b.Width = $w
    $b.Height = 28
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = if ($primary) { $gh.Accent } else { $gh.Border }
    $b.BackColor = if ($primary) { $gh.Accent } else { $gh.Canvas }
    $b.ForeColor = if ($primary) { $gh.White  } else { $gh.Text   }
    $b.Font   = $f9
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function New-TB {
    param([bool]$pass = $false, [bool]$ro = $false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.BorderStyle = 'FixedSingle'
    $t.BackColor   = $gh.Bg
    $t.ForeColor   = $gh.Text
    $t.Font        = $f9
    if ($pass) { $t.UseSystemPasswordChar = $true }
    if ($ro)   { $t.ReadOnly = $true; $t.BackColor = $gh.Canvas; $t.ForeColor = $gh.Muted }
    return $t
}

function Add-HLine {
    param($panel)
    $panel.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($gh.Border, 1)
        $e.Graphics.DrawLine($pen, 0, $s.Height - 1, $s.Width, $s.Height - 1)
        $pen.Dispose()
    })
}

# ==================================================================
#  Input Dialog
# ==================================================================
function Show-Input {
    param([string]$title, [string]$prompt, [string]$default = "")
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.Size = New-Object System.Drawing.Size(420, 160)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.BackColor   = $gh.Bg
    $d.Font        = $f9

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $prompt
    $lbl.Location = New-Object System.Drawing.Point(14, 14)
    $lbl.Size     = New-Object System.Drawing.Size(385, 18)
    $lbl.ForeColor = $gh.Text

    $tb = New-TB; $tb.Text = $default
    $tb.Location = New-Object System.Drawing.Point(14, 40)
    $tb.Width    = 385

    $ok  = New-Btn "OK"     88 $true
    $ok.Location  = New-Object System.Drawing.Point(218, 84)
    $ok.DialogResult = 'OK'

    $can = New-Btn "Cancel" 88
    $can.Location = New-Object System.Drawing.Point(314, 84)
    $can.DialogResult = 'Cancel'

    $d.AcceptButton = $ok
    $d.CancelButton = $can
    $d.Controls.AddRange(@($lbl, $tb, $ok, $can))

    if ($d.ShowDialog() -eq 'OK') { return $tb.Text }
    return $null
}

# ==================================================================
#  SSH / SFTP Operations
# ==================================================================
function Connect-SSH {
    param([string]$hst, [int]$port, [string]$user, [System.Security.SecureString]$secpw)
    try {
        Set-Status "Connecting to ${hst}:${port}..."
        $cred = New-Object System.Management.Automation.PSCredential($user, $secpw)
        $script:SSH_S  = New-SSHSession  -ComputerName $hst -Port $port -Credential $cred -AcceptKey -Force -ErrorAction Stop
        $script:SFTP_S = New-SFTPSession -ComputerName $hst -Port $port -Credential $cred -AcceptKey -Force -ErrorAction Stop
        $script:Connected = $true
        Set-Status "Connected to $hst as $user" "Ok"
        return $true
    } catch {
        $msg = $_.Exception.Message
        Set-Status "Connection failed: $msg" "Err"
        return $false
    }
}

function Disconnect-SSH {
    try {
        if ($script:SFTP_S) { Remove-SFTPSession -SessionId $script:SFTP_S.SessionId -ErrorAction SilentlyContinue }
        if ($script:SSH_S)  { Remove-SSHSession  -SessionId $script:SSH_S.SessionId  -ErrorAction SilentlyContinue }
    } finally {
        $script:SFTP_S    = $null
        $script:SSH_S     = $null
        $script:Connected = $false
    }
}

function List-Remote {
    param([string]$path)
    try {
        return Get-SFTPChildItem -SessionId $script:SFTP_S.SessionId -Path $path -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        Set-Status "List failed: $msg" "Err"
        return @()
    }
}

function SSH-Cmd {
    param([string]$cmd)
    try {
        $r = Invoke-SSHCommand -SessionId $script:SSH_S.SessionId -Command $cmd -ErrorAction Stop
        if ($r.ExitStatus -ne 0) {
            $errText = ($r.Error -join "; ")
            throw $errText
        }
        return $true
    } catch {
        $msg = $_.Exception.Message
        Set-Status "Remote command failed: $msg" "Err"
        return $false
    }
}

# ==================================================================
#  ListView Factory
# ==================================================================
function Make-LV {
    param([bool]$multi = $false)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $false
    $lv.BorderStyle   = 'None'
    $lv.BackColor     = $gh.Bg
    $lv.ForeColor     = $gh.Text
    $lv.Font          = $f9
    $lv.HideSelection = $false
    $lv.MultiSelect   = $multi
    $lv.Dock          = 'Fill'
    foreach ($c in @(@{N="Name";W=240},@{N="Size";W=78},@{N="Type";W=62},@{N="Modified";W=132})) {
        $col = New-Object System.Windows.Forms.ColumnHeader
        $col.Text  = $c.N
        $col.Width = $c.W
        $lv.Columns.Add($col) | Out-Null
    }
    return $lv
}

function Add-LI {
    param($lv, [string]$name, [string]$size, [string]$type, [string]$date, $clr, $tag)
    $li = New-Object System.Windows.Forms.ListViewItem($name)
    $li.SubItems.Add($size) | Out-Null
    $li.SubItems.Add($type) | Out-Null
    $li.SubItems.Add($date) | Out-Null
    $li.ForeColor = $clr
    $li.Tag       = $tag
    $lv.Items.Add($li) | Out-Null
}

# ==================================================================
#  View Refreshers
# ==================================================================
function Refresh-Local {
    $script:lvL.Items.Clear()
    $script:tbLP.Text = $script:LocalPath
    $parent = Split-Path $script:LocalPath -Parent
    if ($parent -and $parent -ne $script:LocalPath) {
        Add-LI $script:lvL ".. [up]" "" "<DIR>" "" $gh.Muted @{T="Up"; P=$parent}
    }
    try {
        Get-ChildItem -LiteralPath $script:LocalPath -Directory -ErrorAction Stop |
            Sort-Object Name | ForEach-Object {
                $dt = $_.LastWriteTime.ToString("yyyy-MM-dd  HH:mm")
                Add-LI $script:lvL ("[DIR] " + $_.Name) "" "<DIR>" $dt $gh.Accent @{T="Dir"; P=$_.FullName; N=$_.Name}
            }
        Get-ChildItem -LiteralPath $script:LocalPath -File -ErrorAction Stop |
            Sort-Object Name | ForEach-Object {
                $dt = $_.LastWriteTime.ToString("yyyy-MM-dd  HH:mm")
                Add-LI $script:lvL $_.Name (Fmt-Size $_.Length) "File" $dt $gh.Text @{T="File"; P=$_.FullName; N=$_.Name}
            }
    } catch {
        $msg = $_.Exception.Message
        Set-Status "Cannot read local path: $msg" "Err"
    }
}

function Refresh-Remote {
    $script:lvR.Items.Clear()
    $script:tbRP.Text = $script:RemotePath
    if (-not $script:Connected) { return }
    if ($script:RemotePath -ne "/") {
        $up = Parent-Remote $script:RemotePath
        Add-LI $script:lvR ".. [up]" "" "<DIR>" "" $gh.Muted @{T="Up"; P=$up}
    }
    $all   = List-Remote $script:RemotePath
    $dirs  = $all | Where-Object { $_.IsDirectory    -and $_.Name -notin @(".", "..") } | Sort-Object Name
    $files = $all | Where-Object { -not $_.IsDirectory -and $_.Name -notin @(".", "..") } | Sort-Object Name
    foreach ($i in $dirs) {
        $dt = $i.LastWriteTime.ToString("yyyy-MM-dd  HH:mm")
        $fp = Join-Remote $script:RemotePath $i.Name
        Add-LI $script:lvR ("[DIR] " + $i.Name) "" "<DIR>" $dt $gh.Accent @{T="Dir"; P=$fp; N=$i.Name}
    }
    foreach ($i in $files) {
        $dt = $i.LastWriteTime.ToString("yyyy-MM-dd  HH:mm")
        $fp = Join-Remote $script:RemotePath $i.Name
        Add-LI $script:lvR $i.Name (Fmt-Size $i.Length) "File" $dt $gh.Text @{T="File"; P=$fp; N=$i.Name}
    }
}

# ==================================================================
#  File Transfer and Server-Side Operations
# ==================================================================
function Op-Upload {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sels = @($script:lvL.SelectedItems | Where-Object { $_.Tag.T -eq "File" })
    if ($sels.Count -eq 0) { Set-Status "Select a local file to upload." "Err"; return }
    $dest = $script:RemotePath.TrimEnd('/')
    foreach ($s in $sels) {
        $name = $s.Tag.N
        Set-Status "Uploading $name..."
        try {
            Set-SFTPItem -SessionId $script:SFTP_S.SessionId -Path $s.Tag.P -Destination $dest -Force -ErrorAction Stop
            Set-Status "Uploaded: $name" "Ok"
        } catch {
            $msg = $_.Exception.Message
            Set-Status "Upload failed: $msg" "Err"
        }
    }
    Refresh-Remote
}

function Op-Download {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sels = @($script:lvR.SelectedItems | Where-Object { $_.Tag.T -eq "File" })
    if ($sels.Count -eq 0) { Set-Status "Select a remote file to download." "Err"; return }
    foreach ($s in $sels) {
        $name = $s.Tag.N
        Set-Status "Downloading $name..."
        try {
            Get-SFTPItem -SessionId $script:SFTP_S.SessionId -Path $s.Tag.P -Destination $script:LocalPath -Force -ErrorAction Stop
            Set-Status "Downloaded: $name" "Ok"
        } catch {
            $msg = $_.Exception.Message
            Set-Status "Download failed: $msg" "Err"
        }
    }
    Refresh-Local
}

function Op-Delete {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sel = $script:lvR.SelectedItems | Select-Object -First 1
    if (-not $sel -or $sel.Tag.T -eq "Up") { Set-Status "Select a remote item to delete." "Err"; return }
    $name = $sel.Tag.N
    $q = [System.Windows.Forms.MessageBox]::Show(
        "Permanently delete '$name' from the server?`nThis action cannot be undone.",
        "Confirm Delete",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($q -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $escapedPath = Esc $sel.Tag.P
    $cmd = if ($sel.Tag.T -eq "Dir") { "rm -rf '$escapedPath'" } else { "rm -f '$escapedPath'" }
    if (SSH-Cmd $cmd) { Set-Status "Deleted: $name" "Ok"; Refresh-Remote }
}

function Op-Rename {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sel = $script:lvR.SelectedItems | Select-Object -First 1
    if (-not $sel -or $sel.Tag.T -eq "Up") { Set-Status "Select a remote item to rename." "Err"; return }
    $newName = Show-Input "Rename" "Enter a new name for '$($sel.Tag.N)':" $sel.Tag.N
    if (-not $newName -or $newName -eq $sel.Tag.N) { return }
    $newPath    = Join-Remote $script:RemotePath $newName
    $srcEscaped = Esc $sel.Tag.P
    $dstEscaped = Esc $newPath
    if (SSH-Cmd "mv '$srcEscaped' '$dstEscaped'") {
        Set-Status "Renamed to: $newName" "Ok"
        Refresh-Remote
    }
}

function Op-Copy {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sel = $script:lvR.SelectedItems | Select-Object -First 1
    if (-not $sel -or $sel.Tag.T -eq "Up") { Set-Status "Select a remote item to copy." "Err"; return }
    $destDir = Show-Input "Server-Side Copy" "Destination directory on the server:" $script:RemotePath
    if (-not $destDir) { return }
    $flag       = if ($sel.Tag.T -eq "Dir") { "-r " } else { "" }
    $srcEscaped = Esc $sel.Tag.P
    $dstEscaped = Esc $destDir.TrimEnd('/')
    if (SSH-Cmd "cp ${flag}'$srcEscaped' '$dstEscaped/'") {
        Set-Status "Copied '$($sel.Tag.N)' to $destDir" "Ok"
        Refresh-Remote
    }
}

function Op-Move {
    if (-not $script:Connected) { Set-Status "Not connected." "Err"; return }
    $sel = $script:lvR.SelectedItems | Select-Object -First 1
    if (-not $sel -or $sel.Tag.T -eq "Up") { Set-Status "Select a remote item to move." "Err"; return }
    $destDir = Show-Input "Server-Side Move" "Destination directory on the server:" $script:RemotePath
    if (-not $destDir) { return }
    $srcEscaped = Esc $sel.Tag.P
    $dstEscaped = Esc $destDir.TrimEnd('/')
    if (SSH-Cmd "mv '$srcEscaped' '$dstEscaped/'") {
        Set-Status "Moved '$($sel.Tag.N)' to $destDir" "Ok"
        Refresh-Remote
    }
}

# ==================================================================
#  GUI Builder
# ==================================================================
function Build-UI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = "xSSH File Transfer v1.0  -  xsukax"
    $form.Size          = New-Object System.Drawing.Size(1120, 720)
    $form.MinimumSize   = New-Object System.Drawing.Size(920, 600)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor     = $gh.Bg
    $form.Font          = $f9
    $script:frmMain     = $form

    # -- Connection Bar --------------------------------------------
    $pConn = New-Object System.Windows.Forms.Panel
    $pConn.Height    = 54
    $pConn.Dock      = 'Top'
    $pConn.BackColor = $gh.Canvas
    Add-HLine $pConn

    $y = 13
    $lbH = New-Object System.Windows.Forms.Label
    $lbH.Text = "Host / IP"; $lbH.AutoSize = $true
    $lbH.Location = New-Object System.Drawing.Point(10, $y)
    $lbH.ForeColor = $gh.Muted; $lbH.Font = $f9

    $script:tbH = New-TB
    $script:tbH.Location = New-Object System.Drawing.Point(72, ($y - 2))
    $script:tbH.Width = 190

    $lbP = New-Object System.Windows.Forms.Label
    $lbP.Text = "Port"; $lbP.AutoSize = $true
    $lbP.Location = New-Object System.Drawing.Point(272, $y)
    $lbP.ForeColor = $gh.Muted; $lbP.Font = $f9

    $script:tbPo = New-TB
    $script:tbPo.Location = New-Object System.Drawing.Point(302, ($y - 2))
    $script:tbPo.Width = 50
    $script:tbPo.Text  = "22"

    $lbU = New-Object System.Windows.Forms.Label
    $lbU.Text = "Username"; $lbU.AutoSize = $true
    $lbU.Location = New-Object System.Drawing.Point(364, $y)
    $lbU.ForeColor = $gh.Muted; $lbU.Font = $f9

    $script:tbU = New-TB
    $script:tbU.Location = New-Object System.Drawing.Point(436, ($y - 2))
    $script:tbU.Width = 145

    $lbPw = New-Object System.Windows.Forms.Label
    $lbPw.Text = "Password"; $lbPw.AutoSize = $true
    $lbPw.Location = New-Object System.Drawing.Point(592, $y)
    $lbPw.ForeColor = $gh.Muted; $lbPw.Font = $f9

    $script:tbPw = New-TB $true
    $script:tbPw.Location = New-Object System.Drawing.Point(658, ($y - 2))
    $script:tbPw.Width = 145

    $script:btnConn = New-Btn "Connect"    100 $true
    $script:btnConn.Location = New-Object System.Drawing.Point(814, ($y - 2))

    $script:btnDisc = New-Btn "Disconnect" 108
    $script:btnDisc.Location = New-Object System.Drawing.Point(922, ($y - 2))
    $script:btnDisc.ForeColor = $gh.Red
    $script:btnDisc.Enabled   = $false

    $pConn.Controls.AddRange(@($lbH, $script:tbH, $lbP, $script:tbPo, $lbU, $script:tbU, $lbPw, $script:tbPw, $script:btnConn, $script:btnDisc))

    # -- Status Bar ------------------------------------------------
    $pStat = New-Object System.Windows.Forms.Panel
    $pStat.Height    = 28
    $pStat.Dock      = 'Bottom'
    $pStat.BackColor = $gh.Canvas
    $pStat.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($gh.Border, 1)
        $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0)
        $pen.Dispose()
    })

    $script:lblStat = New-Object System.Windows.Forms.Label
    $script:lblStat.Text      = "Ready - not connected."
    $script:lblStat.Dock      = 'Fill'
    $script:lblStat.ForeColor = $gh.Muted
    $script:lblStat.Font      = $f9
    $script:lblStat.TextAlign = 'MiddleLeft'
    $script:lblStat.Padding   = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
    $pStat.Controls.Add($script:lblStat)

    # -- Toolbar ---------------------------------------------------
    $pTool = New-Object System.Windows.Forms.Panel
    $pTool.Height    = 44
    $pTool.Dock      = 'Bottom'
    $pTool.BackColor = $gh.Canvas
    $pTool.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($gh.Border, 1)
        $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0)
        $pen.Dispose()
    })

    $script:btnUp  = New-Btn "Upload"    90  $true
    $script:btnDn  = New-Btn "Download"  98
    $script:btnDel = New-Btn "Delete"    82
    $script:btnRen = New-Btn "Rename"    82
    $script:btnCp  = New-Btn "Copy"      74
    $script:btnMv  = New-Btn "Move"      74

    $tx = 10
    foreach ($btn in @($script:btnUp, $script:btnDn, $script:btnDel, $script:btnRen, $script:btnCp, $script:btnMv)) {
        $btn.Location = New-Object System.Drawing.Point($tx, 8)
        $tx += $btn.Width + 6
        $pTool.Controls.Add($btn)
    }
    foreach ($sx in @(206, 372)) {
        $sep = New-Object System.Windows.Forms.Label
        $sep.Width     = 1
        $sep.Height    = 26
        $sep.BackColor = $gh.Border
        $sep.Location  = New-Object System.Drawing.Point($sx, 9)
        $pTool.Controls.Add($sep)
    }

    # -- File Browser (Split) --------------------------------------
    $pBrow = New-Object System.Windows.Forms.Panel
    $pBrow.Dock = 'Fill'

    $script:split = New-Object System.Windows.Forms.SplitContainer
    $split = $script:split
    $split.Dock          = 'Fill'
    $split.SplitterWidth = 5
    $split.BackColor     = $gh.Border
    $split.Panel1.BackColor = $gh.Bg
    $split.Panel2.BackColor = $gh.Bg
    # MinSize is applied after layout in the Shown event to avoid SplitterDistance validation errors

    # Local panel
    $pL = New-Object System.Windows.Forms.Panel; $pL.Dock = 'Fill'

    $tlpL = New-Object System.Windows.Forms.TableLayoutPanel
    $tlpL.Dock = 'Top'; $tlpL.Height = 36; $tlpL.ColumnCount = 3; $tlpL.RowCount = 1; $tlpL.BackColor = $gh.Canvas
    $tlpL.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
    $tlpL.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))     | Out-Null
    $tlpL.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $tlpL.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))     | Out-Null

    $lLbl = New-Object System.Windows.Forms.Label
    $lLbl.Text = "LOCAL"; $lLbl.Font = $f9b; $lLbl.ForeColor = $gh.Text
    $lLbl.Dock = 'Fill'; $lLbl.TextAlign = 'MiddleLeft'
    $lLbl.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

    $script:tbLP = New-TB $false $true
    $script:tbLP.Dock = 'Fill'; $script:tbLP.BorderStyle = 'None'
    $script:tbLP.BackColor = $gh.Canvas; $script:tbLP.Font = $f9m
    $script:tbLP.ReadOnly  = $false

    $btnBrws = New-Btn "Browse" 72
    $btnBrws.Height  = 24
    $btnBrws.Margin  = New-Object System.Windows.Forms.Padding(4, 2, 0, 2)

    $tlpL.Controls.Add($lLbl,    0, 0)
    $tlpL.Controls.Add($script:tbLP, 1, 0)
    $tlpL.Controls.Add($btnBrws, 2, 0)
    Add-HLine $tlpL

    $script:lvL = Make-LV $true

    $pL.Controls.Add($script:lvL)
    $pL.Controls.Add($tlpL)

    # Remote panel
    $pR = New-Object System.Windows.Forms.Panel; $pR.Dock = 'Fill'

    $tlpR = New-Object System.Windows.Forms.TableLayoutPanel
    $tlpR.Dock = 'Top'; $tlpR.Height = 36; $tlpR.ColumnCount = 3; $tlpR.RowCount = 1; $tlpR.BackColor = $gh.Canvas
    $tlpR.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
    $tlpR.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))     | Out-Null
    $tlpR.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $tlpR.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))     | Out-Null

    $rLbl = New-Object System.Windows.Forms.Label
    $rLbl.Text = "REMOTE"; $rLbl.Font = $f9b; $rLbl.ForeColor = $gh.Text
    $rLbl.Dock = 'Fill'; $rLbl.TextAlign = 'MiddleLeft'
    $rLbl.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

    $script:tbRP = New-TB $false $true
    $script:tbRP.Dock = 'Fill'; $script:tbRP.BorderStyle = 'None'
    $script:tbRP.BackColor = $gh.Canvas; $script:tbRP.Font = $f9m
    $script:tbRP.ReadOnly  = $false

    $btnRef = New-Btn "Refresh" 72
    $btnRef.Height = 24
    $btnRef.Margin = New-Object System.Windows.Forms.Padding(4, 2, 0, 2)

    $tlpR.Controls.Add($rLbl,    0, 0)
    $tlpR.Controls.Add($script:tbRP, 1, 0)
    $tlpR.Controls.Add($btnRef,  2, 0)
    Add-HLine $tlpR

    $script:lvR = Make-LV $false

    $pR.Controls.Add($script:lvR)
    $pR.Controls.Add($tlpR)

    $split.Panel1.Controls.Add($pL)
    $split.Panel2.Controls.Add($pR)
    $pBrow.Controls.Add($split)

    # -- Assemble --------------------------------------------------
    $form.Controls.Add($pBrow)
    $form.Controls.Add($pTool)
    $form.Controls.Add($pStat)
    $form.Controls.Add($pConn)

    # ==============================================================
    #  Event Wiring
    # ==============================================================

    # Connect action (shared by button and Enter key)
    $connectAction = {
        if ([string]::IsNullOrWhiteSpace($script:tbH.Text) -or [string]::IsNullOrWhiteSpace($script:tbU.Text)) {
            Set-Status "Host and Username are required." "Err"
            return
        }
        [int]$port = 22
        [int]::TryParse($script:tbPo.Text, [ref]$port) | Out-Null
        $rawPw = $script:tbPw.Text
        $secPw = ConvertTo-SecureString $rawPw -AsPlainText -Force
        $script:tbPw.Text = ""        # Clear password from UI immediately
        $ok = Connect-SSH $script:tbH.Text $port $script:tbU.Text $secPw
        $secPw.Dispose()              # Dispose SecureString after use
        if ($ok) {
            $script:btnConn.Enabled = $false
            $script:btnDisc.Enabled = $true
            $script:tbH.ReadOnly    = $true
            $script:tbPo.ReadOnly   = $true
            $script:tbU.ReadOnly    = $true
            $script:RemotePath      = "/"
            Refresh-Remote
        }
    }

    $script:btnConn.Add_Click($connectAction)
    $script:tbPw.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { & $connectAction }
    })

    # Disconnect
    $script:btnDisc.Add_Click({
        Disconnect-SSH
        $script:lvR.Items.Clear()
        $script:tbRP.Text = ""
        $script:btnConn.Enabled = $true
        $script:btnDisc.Enabled = $false
        $script:tbH.ReadOnly    = $false
        $script:tbPo.ReadOnly   = $false
        $script:tbU.ReadOnly    = $false
        Set-Status "Disconnected."
    })

    # Local path bar: type a path and press Enter to navigate
    $script:tbLP.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $p = $script:tbLP.Text.Trim()
            if ($p -and (Test-Path -LiteralPath $p)) {
                $script:LocalPath = $p
                Refresh-Local
            } else {
                Set-Status "Local path not found: $p" "Err"
            }
            $_.Handled = $true
        }
    })

    # Remote path bar: type a path and press Enter to navigate
    $script:tbRP.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return -and $script:Connected) {
            $script:RemotePath = $script:tbRP.Text.Trim()
            Refresh-Remote
            $_.Handled = $true
        }
    })

    # Browse local folder
    $btnBrws.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $script:LocalPath
        $dlg.Description  = "Select local working folder"
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:LocalPath = $dlg.SelectedPath
            Refresh-Local
        }
    })

    # Refresh remote
    $btnRef.Add_Click({ Refresh-Remote })

    # Local double-click navigation
    $script:lvL.Add_DoubleClick({
        $sel = $script:lvL.SelectedItems | Select-Object -First 1
        if ($sel -and ($sel.Tag.T -eq "Dir" -or $sel.Tag.T -eq "Up")) {
            $script:LocalPath = $sel.Tag.P
            Refresh-Local
        }
    })

    # Remote double-click navigation
    $script:lvR.Add_DoubleClick({
        $sel = $script:lvR.SelectedItems | Select-Object -First 1
        if ($sel -and ($sel.Tag.T -eq "Dir" -or $sel.Tag.T -eq "Up")) {
            $script:RemotePath = $sel.Tag.P
            Refresh-Remote
        }
    })

    # Toolbar operations
    $script:btnUp.Add_Click({  Op-Upload   })
    $script:btnDn.Add_Click({  Op-Download })
    $script:btnDel.Add_Click({ Op-Delete   })
    $script:btnRen.Add_Click({ Op-Rename   })
    $script:btnCp.Add_Click({  Op-Copy     })
    $script:btnMv.Add_Click({  Op-Move     })

    # Set splitter minimum sizes after the form has been laid out
    $form.Add_Shown({
        $script:split.Panel1MinSize = 200
        $script:split.Panel2MinSize = 200
    })

    # Cleanup on close
    $form.Add_FormClosing({ Disconnect-SSH })

    Refresh-Local
    return $form
}

# ==================================================================
#  Entry Point
# ==================================================================
[System.Windows.Forms.Application]::Run((Build-UI))