$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BuildVer = '2026.11.27.10'

# ---- 单实例保护：已经有一只猫在跑就不再启动第二只 ----
try {
    $others = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*pet3d.ps1*' }
    if ($others) { exit }
} catch { }
$Runtime = Join-Path $Root 'runtime'
New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
$SettingsPath = Join-Path $Runtime 'settings.json'
$CatsPath = Join-Path $Root 'cats.json'
$LogPath = Join-Path $Runtime 'pet3d.log'

function Log([string]$m) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    Add-Content -Path $LogPath -Value ("[$ts] " + $m) -Encoding UTF8
}

# 分段数值比较版本号：避免字符串字典序把 '2026.11.27.8' 判成高于 '2026.11.27.10'
function Test-NewerVersion([string]$remote, [string]$local) {
    $ra = $remote.Split('.'); $la = $local.Split('.')
    $n = [Math]::Max($ra.Length, $la.Length)
    for ($i = 0; $i -lt $n; $i++) {
        $rv = 0; $lv = 0
        [void][int]::TryParse($ra[$i], [ref]$rv)
        [void][int]::TryParse($la[$i], [ref]$lv)
        if ($rv -gt $lv) { return $true }
        if ($rv -lt $lv) { return $false }
    }
    return $false
}

# ---------- single instance ----------
$mutex = New-Object System.Threading.Mutex($false, 'Local\pet3d_desktop_cat')
if (-not $mutex.WaitOne(0)) { [System.Windows.MessageBox]::Show('already running'); exit }

# ---------- WebView2 assemblies ----------
$Lib = Join-Path $Root 'lib'
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $Lib 'Microsoft.Web.WebView2.Core.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $Lib 'Microsoft.Web.WebView2.Wpf.dll'))

# ---------- state ----------
$Defaults = @{
    cat = 'orange'; scale = 0.9; opacity = 1.0; x = -1; y = -1;
    topmost = $true; clickThrough = $false; bowl = $true; food = 50;
    sleepMinutes = 1; layout = '65'; socialRoom = '482101'; socialNick = 'pet'; kittens = @(); model = 'real-ragdoll'; patrol = $true; migrated3d = $false
}
$script:S = @{}
if (Test-Path $SettingsPath) {
    try {
        $loaded = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasModelKey = ($loaded.PSObject.Properties.Name -contains 'model')
        foreach ($k in $Defaults.Keys) {
            if ($loaded.PSObject.Properties.Name -contains $k) { $script:S[$k] = $loaded.$k }
            else { $script:S[$k] = $Defaults[$k] }
        }
    } catch { $script:S = $Defaults.Clone() }
} else { $script:S = $Defaults.Clone() }
if (-not (Get-Variable hasModelKey -Scope 0 -ErrorAction SilentlyContinue)) { $hasModelKey = $false }
if ($hasModelKey -eq $false) { $script:S['model'] = 'real-ragdoll' }
if ([string]$script:S['model'] -eq '') { $script:S['model'] = 'real-ragdoll' }

function Save-Settings {
    $script:S | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsPath -Encoding UTF8
}

# ---- 一次性模型迁移：老用户（空 model 或旧照片包 real-ragdoll）默认切到 3D 骨骼猫；
# 迁移只做一次（migrated3d 标记落盘），之后用户手动切回照片猫/none 不被再次覆盖 ----
if (-not [bool]$script:S['migrated3d']) {
    $curModel = [string]$script:S['model']
    if ($curModel -eq '' -or $curModel -eq 'real-ragdoll') {
        $script:S['model'] = 'ragdoll3d'
        $script:S['migrated3d'] = $true
        Log 'migrate: default model -> ragdoll3d'
    } else {
        $script:S['migrated3d'] = $true
    }
    Save-Settings
}

if (-not (Test-Path $SettingsPath)) { try { Save-Settings } catch { } }

$script:Peers = @{}
$script:SocialOn = $false
$script:HugNo = 0
$script:PanelOn = $false
$script:DragIdle = 0

# ---------- cats ----------
if (-not (Test-Path $CatsPath)) { throw "cats.json missing" }
$script:CatsDoc = Get-Content $CatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-CatById([string]$id) {
    foreach ($c in $script:CatsDoc.cats) { if ($c.id -eq $id) { return $c } }
    return $null
}
function Save-Cats { $script:CatsDoc | ConvertTo-Json -Depth 8 | Set-Content -Path $CatsPath -Encoding UTF8 }

# ---------- window ----------
$BaseW = 300; $BaseH = 272
$scaleNow = [double]$script:S['scale']
$winW = [int]([Math]::Round($BaseW * $scaleNow))
$winH = [int]([Math]::Round($BaseH * $scaleNow))

$win = New-Object System.Windows.Window
$win.Dispatcher.add_UnhandledException({
    param($s, $e)
    try { Log ("UNHANDLED: " + $e.Exception.Message + ' @ ' + $e.Exception.StackTrace) } catch {}
    $e.Handled = $true
})
$win.WindowStyle = 'None'
$win.Title = 'Pet3D'
$win.AllowsTransparency = $false
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.ResizeMode = 'NoResize'
$win.ShowInTaskbar = $false
$win.Topmost = [bool]$script:S['topmost']
$win.Width = $winW; $win.Height = $winH

$wa = [System.Windows.SystemParameters]::WorkArea
$x = [double]$script:S['x']; $y = [double]$script:S['y']
if ($x -lt 0 -or $y -lt 0) {
    $x = $wa.Right - $winW - 40
    $y = $wa.Bottom - $winH - 60
}
$win.Left = $x; $win.Top = $y

$grid = New-Object System.Windows.Controls.Grid
$win.Content = $grid

$wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
$cp.UserDataFolder = (Join-Path $Runtime 'wv')
$wv.CreationProperties = $cp
$wv.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
$grid.Children.Add($wv)

$script:Ready = $false
$script:DragFrom = $null
$script:DragStartX = 0
$script:DragStartY = 0

function Run-Js([string]$expr) {
    if (-not $script:Ready) { return }
    if (-not $script:Core) { return }
    # fire-and-forget: blocking on .Result on the UI thread deadlocks the dispatcher
    try { $null = $script:Core.ExecuteScriptAsync($expr) } catch { Log "js fail: $($_.Exception.Message)" }
}

function Set-Bubble([string]$text) {
    $j = ConvertTo-Json $text -Compress
    $null = Run-Js "window.pet.say($j)"
}

function Apply-Coat {
    $cat = Get-CatById ([string]$script:S['cat'])
    if (-not $cat) {
        $script:S['cat'] = 'orange'
        Save-Settings
        $cat = Get-CatById 'orange'
    }
    if (-not $cat) { return }
    $obj = @{ kind = $cat.kind; id = $cat.id }
    if ($cat.kind -eq 'custom') {
        $obj.fur = $cat.fur; $obj.patch = $cat.patch; $obj.accent = $cat.accent
        $obj.eye = $cat.eye; $obj.eye2 = $cat.eye2; $obj.pattern = $cat.pattern
        $spots = @()
        if ($cat.PSObject.Properties.Name -contains 'spots' -and $cat.spots) { $spots = $cat.spots }
        $obj.spots = @($spots)
    }
    # 外观包热更：packs\looks\<猫 id>.json 可以覆盖任意一只猫的毛色
    try {
        $lf = Join-Path $script:PackDir ('looks\' + [string]$cat.id + '.json')
        if (Test-Path $lf) {
            $lk = Get-Content $lf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($lk.kind -eq 'custom') {
                $obj.kind = 'custom'
                foreach ($k in @('fur','patch','accent','eye','eye2','pattern')) {
                    if ($lk.PSObject.Properties.Name -contains $k -and $lk.$k) { $obj[$k] = $lk.$k }
                }
            }
        }
    } catch { }
    $j = ConvertTo-Json $obj -Depth 6 -Compress
    $null = Run-Js "window.pet.setCoat($j)"
}

# ---------- 自由配色（仿 7paws 的色槽 + 二级色板） ----------
$script:BuiltinPalette = @{
    'orange'  = @{ fur = '#e9973f'; patch = '#c26a1f'; accent = '#e9973f'; eye = '#6b9440'; pattern = 'tabby' }
    'tabby'   = @{ fur = '#8b8f86'; patch = '#5c8a3a'; accent = '#8b8f86'; eye = '#e2b93b'; pattern = 'tabby' }
    'tuxedo'  = @{ fur = '#f8f6ef'; patch = '#151515'; accent = '#151515'; eye = '#5aa9c9'; pattern = 'bicolor' }
    'calico'  = @{ fur = '#f8f6ef'; patch = '#e9973f'; accent = '#3f3324'; eye = '#e2b93b'; pattern = 'calico' }
    'white'   = @{ fur = '#f8f6ef'; patch = '#f8f6ef'; accent = '#e2b93b'; eye = '#5aa9c9'; pattern = 'solid' }
    'blue'    = @{ fur = '#8090a0'; patch = '#667686'; accent = '#8090a0'; eye = '#e2b93b'; pattern = 'solid' }
    'siamese' = @{ fur = '#fbe8c9'; patch = '#4d3d2b'; accent = '#4d3d2b'; eye = '#5aa9c9'; pattern = 'bicolor' }
}

function Get-PaletteJson {
    $o = @{ fur = '#e9973f'; patch = '#c26a1f'; accent = '#c26a1f'; eye = '#6b9440'; eye2 = '#6b9440'; pattern = 'tabby' }
    $cat = Get-CatById ([string]$script:S['cat'])
    if ($cat) {
        if ($cat.kind -eq 'custom' -and $cat.PSObject.Properties.Name -contains 'fur' -and $cat.fur) {
            foreach ($k in @('fur', 'patch', 'accent', 'eye', 'eye2', 'pattern')) {
                if ($cat.PSObject.Properties.Name -contains $k -and $cat.$k) { $o[$k] = [string]$cat.$k }
            }
        } else {
            $bp = $script:BuiltinPalette[[string]$cat.id]
            if ($bp) {
                foreach ($k in @('fur', 'patch', 'accent', 'eye', 'pattern')) { if ($bp[$k]) { $o[$k] = [string]$bp[$k] } }
                $o['eye2'] = $o['eye']
            }
        }
    }
    return (ConvertTo-Json $o -Compress)
}

function Open-Palette {
    try {
        $j = Get-PaletteJson
        $null = Run-Js ('window.pet.palette(' + $j + ')')
        $script:PanelOn = $true
        Log ('palette open ' + $j)
    } catch { Log ('palette ERR: ' + $_.Exception.Message) }
}
    $script:SelfCoat = $obj

function Apply-Bowl {
    $on = if ([bool]$script:S['bowl']) { 'true' } else { 'false' }
    $f = [int]$script:S['food']
    $null = Run-Js "window.pet.setBowl($on,$f)"
}

function Apply-Opacity {
    $o = [double]$script:S['opacity']
    $null = Run-Js "document.documentElement.style.opacity='$o'"
}

function Resize-Pet([double]$scale) {
    $script:S['scale'] = $scale
    $win.Width = [int]([Math]::Round($BaseW * $scale))
    $win.Height = [int]([Math]::Round($BaseH * $scale))
}

function Feed-Pet([int]$amount) {
    if ($amount -le 0) { $amount = 8 }
    $food = [int]$script:S['food'] + $amount
    if ($food -gt 100) { $food = 100 }
    $script:S['food'] = $food
    $script:S['bowl'] = $true
    Apply-Bowl
    $null = Run-Js "window.pet.feed()"
    $lines = @('吃饱啦，好好吃～', '喵呜，这个我喜欢', '再来一口好不好', '吃得饱饱的，想睡一会儿',
               '谢谢你呀，摸摸头吧', '碗里还有吗？', '好幸福……', '舔舔嘴，真香')
    Set-Bubble ($lines[(Get-Random -Maximum $lines.Count)] + '（饱食度 ' + $food + '）')
    Save-Settings
}

function Breed-Kitten($partnerCoat) {
    if (-not $script:SocialOn) { Set-Bubble '要先联机，和朋友的猫一起才能生小猫'; Log 'breed blocked: offline'; return }
    $klist = @($script:S['kittens'] | Where-Object { [string]$_ } )
    $klist = @($klist | Select-Object -Unique)
    $script:S['kittens'] = $klist
    if ($klist.Count -ge 3) {
        Set-Bubble '已经有 3 只小猫啦，右键「清除小猫」再一起养新的'
        Log 'breed blocked: 3 kittens'
        return
    }
    $pa = Get-CatById ([string]$script:S['cat'])
    if (-not $partnerCoat) { $partnerCoat = $script:PeerCoat }
    if (-not $partnerCoat) { Set-Bubble '需要对方同意'; Log 'breed blocked: no partner coat'; return }
    $pb = $partnerCoat
    if (-not $pb.fur) {
        # 内置猫在 cats.json 里只有 id，没有毛色；用内置色表补出来再参与混色
        $BF = @{ orange = '#e9973f'; tabby = '#c9a77e'; tuxedo = '#2b2b31'; calico = '#f2c68e';
                 white = '#fcfcf9'; blue = '#8090a0'; siamese = '#f4ead9' }
        $bid = [string]$pb.id
        if (-not $BF.ContainsKey($bid)) { $bid = 'orange' }
        $pb = [pscustomobject]@{
            id = $bid; kind = 'builtin'; fur = $BF[$bid]; patch = $BF[$bid]
            accent = '#6b4a35'; eye = '#6b9440'; eye2 = '#6b9440'; pattern = 'bicolor'
        }
    }
    if (-not $pb -or -not $pb.fur) { Set-Bubble '拿不到对方的毛色'; return }

    function HexCh([string]$h, [int]$shift) { return [Convert]::ToInt32($h.Substring(1 + $shift, 2), 16) }
    function MixHex([string]$a, [string]$b, [double]$t) {
        $r = [int]([Math]::Round((HexCh $a 0) * (1 - $t) + (HexCh $b 0) * $t))
        $g = [int]([Math]::Round((HexCh $a 2) * (1 - $t) + (HexCh $b 2) * $t))
        $bl = [int]([Math]::Round((HexCh $a 4) * (1 - $t) + (HexCh $b 4) * $t))
        return ('#{0:x2}{1:x2}{2:x2}' -f $r, $g, $bl)
    }

    $furA = $pa.fur; $furB = $pb.fur
    if (-not $furA) { $furA = '#e9973f' }
    if (-not $furB) { $furB = '#a08a6c' }
    $t = 0.35 + (Get-Random -Minimum 0 -Maximum 30) / 100.0
    $mixFur = MixHex $furA $furB $t
    # 7paws 自动猫色：把混色吸附到预设的可爱色板，保证生出的小猫不脏不灰
    $CuteFurs = @('#f7eddb', '#dcdedd', '#f2a75c', '#6f4b34', '#fdeeee', '#eef0de', '#2b2b31',
                  '#dcc2a4', '#dbcde9', '#fcfcf9', '#f2c68e', '#f3f2ed', '#f4ab60', '#e9973f',
                  '#a08a6c', '#8090a0', '#f4ead9', '#f8f6ef')
    $best = $mixFur; $bd = 1e9; $second = $null; $sd = 1e9
    foreach ($cf in $CuteFurs) {
        $d = 0
        foreach ($sh in @(0, 2, 4)) { $d += [Math]::Abs((HexCh $cf $sh) - (HexCh $mixFur $sh)) }
        if ($d -lt $bd) { $second = $best; $sd = $bd; $best = $cf; $bd = $d }
        elseif ($d -lt $sd) { $second = $cf; $sd = $d }
    }
    $fur = $best
    if ($second -and (Get-Random -Maximum 100) -lt 30) { $fur = $second }
    $patchSource = if ($pb.patch) { $pb.patch } else { $furB }
    $accentSource = if ($pb.accent) { $pb.accent } else { $pb.patch }
    if (-not $accentSource) { $accentSource = $furB }
    $pattern = $pa.pattern
    if ($pa.pattern -eq 'tabby' -and $pb.pattern -eq 'calico') { $pattern = 'calico' }
    if (-not $pattern) { $pattern = 'bicolor' }
    $furLum = ((0.2126 * (HexCh $fur 0)) + (0.7152 * (HexCh $fur 2)) + (0.0722 * (HexCh $fur 4)) + 0.01) / 255
    $patchMix = MixHex $fur $patchSource 0.55
    $pLum = ((0.2126 * (HexCh $patchMix 0)) + (0.7152 * (HexCh $patchMix 2)) + (0.0722 * (HexCh $patchMix 4)) + 0.01) / 255
    $patchV = $patchMix
    if ([Math]::Abs($pLum - $furLum) -lt 0.12) { $patchV = MixHex $fur '#fffdf6' 0.72 }

    $seed = [string]$pa.id + '|' + [string]$pb.id
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex6 = ($sha[0..2] | ForEach-Object { $_.ToString('x2') }) -join ''
    $kittenId = 'kitten-' + $hex6

    $eyeV = '#6b9440'; if ($pa.eye) { $eyeV = $pa.eye }
    $eye2V = $eyeV; if ($pa.eye2) { $eye2V = $pa.eye2 }
    $k = [pscustomobject]@{
        id = $kittenId; kind = 'custom'; name = ('小猫 ' + $hex6)
        fur = $fur; patch = $patchV; accent = $accentSource
        eye = $eyeV
        eye2 = $eye2V
        pattern = $pattern; spots = @(); born = (Get-Date).ToString('s')
        parents = @($pa.id, $pb.id)
    }
    $script:CatsDoc.cats += $k
    Save-Cats

    $list = @($script:S['kittens'])
    if ($list.Count -ge 3) { Set-Bubble '已经有 3 只小猫了，先「清除小猫」'; return }
    $list += $kittenId
    $script:S['kittens'] = $list
    Save-Settings
    Add-KittenWindow $kittenId

    $nameParam = ''
    Show-Cattery (Get-CoatObject $pa.id) (Get-CoatObject $pb.id) (Get-CoatObject $kittenId) $nameParam

    Log "kitten $kittenId from $($pa.id) + $($pb.id)"
}

function New-RandomCat {
    $furs = @('#f7eddb', '#f2a75c', '#dcdedd', '#6f4b34', '#fdeeee', '#eef0de', '#2b2b31',
              '#dcc2a4', '#dbcde9', '#fcfcf9', '#f2c68e', '#f3f2ed', '#f4ab60', '#e9973f',
              '#a08a6c', '#8090a0', '#f4ead9', '#f8f6ef')
    $eyes = @('#7fb2cf', '#86b56a', '#59a6d6', '#e7bd3a', '#8fd0e2', '#dda83c', '#b0824a', '#4aa3d6')
    $accentPool = @('#6b4a35', '#3f4650', '#d97b2a', '#f0b4bf', '#8ea762', '#a17cc0', '#2b2b31', '#7c5c41')
    $pats = @('calico', 'calico', 'calico', 'tabby', 'tabby', 'bicolor')
    $prefix = @('小猫', '小奶', '小橘', '小灰', '小糖', '小雪', '小布', '小茶')
    $fur = $furs[(Get-Random -Maximum $furs.Count)]
    $eye = $eyes[(Get-Random -Maximum $eyes.Count)]
    $pat = $pats[(Get-Random -Maximum $pats.Count)]
    $patch = $fur
    $accent = $accentPool[(Get-Random -Maximum $accentPool.Count)]
    if ($pat -eq 'bicolor') { $patch = '#fdf7ec'; $accent = $fur }
    $hex4 = ''
    for ($i = 0; $i -lt 4; $i++) { $hex4 += '0123456789abcdef'[(Get-Random -Maximum 16)] }
    $id = 'rand-' + $hex4
    $nm = $prefix[(Get-Random -Maximum $prefix.Count)] + ' ' + $hex4
    $obj = [pscustomobject]@{ id = $id; kind = 'custom'; name = $nm; fur = $fur; patch = $patch
                              accent = $accent; eye = $eye; eye2 = $eye; pattern = $pat
                              spots = @(); born = (Get-Date).ToString('s') }
    $script:CatsDoc.cats += $obj
    Save-Cats
    $script:S['cat'] = $id
    Apply-Coat
    Save-Settings
    Log ('random cat ' + $id + ' ' + $pat + ' ' + $fur)
    Set-Bubble ('新猫来啦：' + $nm)
}

# ---------- 常驻小猫窗口 ----------
$script:KittenWins = @()
$script:LastKL = -99999; $script:LastKT = -99999

function Get-CoatJson([string]$id) {
    $cat = Get-CatById $id
    if (-not $cat) { return $null }
    $obj = @{ kind = [string]$cat.kind; id = [string]$cat.id }
    if ($cat.kind -eq 'custom') {
        $obj.fur = $cat.fur; $obj.patch = $cat.patch; $obj.accent = $cat.accent
        $obj.eye = $cat.eye; $obj.eye2 = $cat.eye; $obj.pattern = $cat.pattern
        $obj.spots = @()
        if ($cat.PSObject.Properties.Name -contains 'eye2' -and $cat.eye2) { $obj.eye2 = $cat.eye2 }
    }
    return (ConvertTo-Json $obj -Depth 6 -Compress)
}

function Move-Kittens {
    if ($script:KittenWins.Count -eq 0) { return }
    $wa = [System.Windows.SystemParameters]::WorkArea
    $kw0 = $script:KittenWins[0].Win
    $step = [double]$kw0.Width * 0.62
    $need = $script:KittenWins.Count * $step
    $base = $win.Left - $need + 30
    if ($base -lt ($wa.Left + 4)) { $base = $win.Right - ($script:KittenWins.Count * $step) + 10 }
    for ($i = 0; $i -lt $script:KittenWins.Count; $i++) {
        $kw = $script:KittenWins[$i].Win
        try {
            $kw.Left = $base + ($i * $step)
            $kw.Top = $win.Top + $win.Height - $kw.Height + 10
            if ($kw.Left -lt ($wa.Left + 2)) { $kw.Left = $wa.Left + 2 }
            if (($kw.Left + $kw.Width) -gt ($wa.Right - 2)) { $kw.Left = $wa.Right - $kw.Width - 2 }
        } catch { }
    }
}

function Clear-Kittens {
    foreach ($kw in $script:KittenWins) { try { $kw.Win.Close() } catch { } }
    $script:KittenWins = @()
$script:LastKL = -99999; $script:LastKT = -99999
    $script:S['kittens'] = @()
    Save-Settings
}

function Add-KittenWindow([string]$catId) {
    $j = Get-CoatJson $catId
    if (-not $j) { return }
    $script:KittenCoatJson = $j
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $false
    $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false
    $w.Topmost = [bool]$script:S['topmost']
    $w.Width = 190; $w.Height = 182
    $g = New-Object System.Windows.Controls.Grid
    $w.Content = $g
    $nv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $cp.UserDataFolder = (Join-Path $Runtime 'wv')
    $nv.CreationProperties = $cp
    $nv.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
    $g.Children.Add($nv)
    $nv.Tag = @{ core = $null; coat = $script:KittenCoatJson }
    $w.Show()
    try {
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper($w)).Handle
    $script:KCHW = $hw
        $mg = New-Object DwmApi+MARGINS
        $mg.l = -1; $mg.r = -1; $mg.t = -1; $mg.b = -1
        [void][DwmApi]::DwmExtendFrameIntoClientArea($hw, [ref]$mg)
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hw)
        if ($src) { $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent }
        $ex = [WinApi]::GetWindowLong($hw, -20)
        [void][WinApi]::SetWindowLong($hw, -20, $ex -bor 0x20)
    } catch { }
    $nv.add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { return }
        $s.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false
        $p = Join-Path $Root 'cat3d\cat.html'
        $s.CoreWebView2.Navigate('file:///' + ($p -replace '\\', '/') + '?coat=orange&sleep=999&cjson=' + [Uri]::EscapeDataString($script:KittenCoatJson))
        # 小猫窗口纯装饰：把 WebView2 子窗口也设成鼠标穿透，避免挡住下面的按钮
        $kh = $script:KCHW
        $kt = New-Object System.Windows.Threading.DispatcherTimer
        $kt.Interval = [TimeSpan]::FromMilliseconds(900)
        $kt.add_Tick({ param($ts, $te) $ts.Stop(); try { [WinChild]::Clear($kh, $true) } catch { } })
        $kt.Start()
    })
    $nv.add_WebMessageReceived({
        param($s, $e)
        try { $m = $e.WebMessageAsJson | ConvertFrom-Json } catch { return }
        if ($m.t -eq 'ready') {
            try { $null = $s.CoreWebView2.ExecuteScriptAsync('window.pet.setBowl(false,0)') } catch { }
        }
    })
    $script:KittenWins += @{ Win = $w; Wv = $nv }
    $script:KCWV = $nv
    $et = New-Object System.Windows.Threading.DispatcherTimer
    $et.Interval = [TimeSpan]::FromMilliseconds(1200)
    $et.add_Tick({
        param($ts, $te)
        $ts.Stop()
        try { $null = $script:KCWV.EnsureCoreWebView2Async($null) } catch { Log ('kitten ensure: ' + $_.Exception.Message) }
        try { Move-Kittens } catch { Log ('kitten move fail: ' + $_.Exception.Message) }
    })
    $et.Start()
}

function Apply-Kittens {
    foreach ($id in @($script:S['kittens'])) {
        if ([string]$id) { Add-KittenWindow ([string]$id) }
    }
}

function Get-CoatObject([string]$id) {    $c = Get-CatById $id
    if (-not $c) { return @{ kind = 'builtin'; id = 'orange' } }
    if ($c.kind -ne 'custom') { return @{ kind = 'builtin'; id = [string]$c.id } }
    return @{
        kind = 'custom'; id = $c.id; fur = $c.fur; patch = $c.patch; accent = $c.accent
        eye = $c.eye; eye2 = $c.eye2; pattern = $c.pattern; spots = @()
    }
}

function Show-Cattery($coatA, $coatB, $coatK, [string]$nameText) {
    try {
        $cw = New-Object System.Windows.Window
        $cw.WindowStyle = 'None'
        $cw.AllowsTransparency = $true
        $cw.Background = [System.Windows.Media.Brushes]::Transparent
        $cw.ResizeMode = 'NoResize'
        $cw.ShowInTaskbar = $false
        $cw.Topmost = $true
        $cw.Width = 520; $cw.Height = 360
        $cw.WindowStartupLocation = 'CenterScreen'

        $cwv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
        $ccp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
        $ccp.UserDataFolder = (Join-Path $Runtime 'wv')
        $cwv.CreationProperties = $ccp
        $cwv.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
        $cw.Content = $cwv

        $page = Join-Path (Join-Path $Root 'cat3d') 'cattery.html'
        $pageUri = 'file:///' + ($page -replace '\\', '/')

        $ja = ConvertTo-Json $coatA -Depth 5 -Compress
        $jb = ConvertTo-Json $coatB -Depth 5 -Compress
        $jk = ConvertTo-Json $coatK -Depth 5 -Compress
        $jn = ConvertTo-Json $nameText -Compress
        $script:CatteryCall = 'window.startScene(' + $ja + ',' + $jb + ',' + $jk + ',' + $jn + ')'

        $cwv.add_NavigationCompleted({
            param($s, $e)
            if ($e.IsSuccess) {
                try { $null = $s.ExecuteScriptAsync($script:CatteryCall) } catch { Log ("cattery js fail: " + $_.Exception.Message) }
                Log 'cattery scene started'
            } else {
                Log ('cattery nav fail: ' + $e.WebErrorStatus)
            }
        })

        $script:CatteryWin = $cw
        $cw.Show()
        $cwv.Source = [Uri]$pageUri

        $script:CatteryTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CatteryTimer.Interval = [TimeSpan]::FromMilliseconds(6400)
        $script:CatteryTimer.Add_Tick({
            $script:CatteryTimer.Stop()
            try { if ($script:CatteryWin) { $script:CatteryWin.Close() } } catch {}
        })
        $script:CatteryTimer.Start()
        Log ('cattery opened: ' + $pageUri)
    } catch {
        Log ("cattery fail: " + $_.Exception.Message)
    }
}

# ---------- social (ntfy relay) ----------
function Show-HugPair($coat) { Show-Guest $coat '' 'hug' }

function Show-Guest($coat, [string]$text, [string]$mode) {
    try {
        if (-not $coat) { $coat = @{ kind = 'custom'; id = 'cute-ragdoll'; fur = '#f8f2ea'; patch = '#cfc3b8'
                                     accent = '#6a5d56'; eye = '#59a6d6'; eye2 = '#59a6d6'; pattern = 'calico'; spots = @() } }
        $jc = ConvertTo-Json $coat -Depth 6 -Compress
        $jt = ConvertTo-Json ([string]$text) -Compress
        $jm = ConvertTo-Json ([string]$mode) -Compress
        $null = Run-Js ('window.pet.guest(' + $jc + ',' + $jt + ',' + $jm + ')')
    } catch { Log ('guest fail: ' + $_.Exception.Message) }
}

function Last-Peer {    try {
        $k = @($script:Peers.Keys)
        if ($k.Length -gt 0) { return [string]($k[$k.Length - 1]) }
    } catch { }
    return '对方'
}
function Social-Send([hashtable]$msg) {
    if (-not $script:SocialOn) { Set-Bubble '还没联机，右键 联机→连接'; return }
    $j = ConvertTo-Json $msg -Compress -Depth 6
    $null = Run-Js "window.pet.socialSend($j)"
    Log ('social send: ' + $j)
}

function Ask-Text([string]$title, [string]$label, [string]$default) {
    $script:AskVal = $null
    try {
        $w = New-Object System.Windows.Window
        $w.Title = $title
        $w.Width = 380; $w.Height = 170
        $w.WindowStartupLocation = 'CenterScreen'
        $w.Topmost = $true
        $w.ResizeMode = 'NoResize'
        $w.ShowInTaskbar = $true
        $g = New-Object System.Windows.Controls.StackPanel
        $g.Margin = '16'
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $label
        $t.FontSize = 13
        [void]$g.Children.Add($t)
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Text = $default
        $tb.FontSize = 14
        $tb.Padding = '4,2,4,2'
        $tb.Margin = '0,8,0,0'
        [void]$g.Children.Add($tb)
        $btns = New-Object System.Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'
        $btns.HorizontalAlignment = 'Right'
        $btns.Margin = '0,14,0,0'
        $ok = New-Object System.Windows.Controls.Button
        $ok.Content = '确定'; $ok.Width = 86; $ok.Height = 28; $ok.Margin = '0,0,8,0'
        $no = New-Object System.Windows.Controls.Button
        $no.Content = '取消'; $no.Width = 86; $no.Height = 28
        $ok.add_Click({ try { $script:AskVal = $script:AskBox.Text; $script:AskWin.Close() } catch {} })
        $no.add_Click({ $script:AskVal = $null; $script:AskWin.Close() })
        [void]$btns.Children.Add($ok)
        [void]$btns.Children.Add($no)
        [void]$g.Children.Add($btns)
        $w.Content = $g
        $script:AskWin = $w; $script:AskBox = $tb
        $w.add_ContentRendered({ try { $script:AskBox.Focus(); [void]$script:AskBox.SelectAll() } catch {} })
        $w.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $script:AskVal = $script:AskBox.Text; $w.Close() } })
        [void]$w.ShowDialog()
    } catch { Log ('ask-text fail: ' + $_.Exception.Message) }
    return $script:AskVal
}

function Social-Connect {
    $room = Ask-Text '联机 - 房间号' '6 位房号（两台电脑填同一个，例如 482101）' ([string]$script:S['socialRoom'])
    if (-not $room) { return }
    $nick = Ask-Text '联机 - 昵称' '你的昵称（两台填不一样的，例如 catA / catB）' ([string]$script:S['socialNick'])
    if (-not $nick) { $nick = 'pet' }
    $room = ($room -replace '[^0-9]', '')
    if ($room.Length -ne 6) { Set-Bubble '房号必须是 6 位数字'; return }
    $script:S['socialRoom'] = $room
    $script:S['socialNick'] = $nick
    Save-Settings
    $r = $room -replace "'", ''
    $n = $nick -replace "'", ''
    $null = Run-Js "window.pet.socialConnect('$r','$n')"
    Set-Bubble ('正在连接房间 ' + $room + ' …')
}

# ---------- context menu ----------
# ---------- 外观模型（照片级真猫，外观包热更） ----------
function Get-Models {
    $list = @()
    $dir = Join-Path $Root 'runtime\packs\models'
    if (Test-Path $dir) {
        foreach ($d in (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue)) {
            $pj = Join-Path $d.FullName 'pack.json'
            if (-not (Test-Path $pj)) { continue }
            try {
                $o = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                $list += [pscustomobject]@{ id = [string]$o.id; name = [string]$o.name; kind = [string]$o.kind; ver = [string]$o.ver }
            } catch { }
        }
    }
    return ,$list
}
function Apply-Model {
    $id = [string]$script:S['model']
    if (($id -eq '') -or ($id -eq 'none')) { $null = Run-Js 'window.pet.modelOff()'; return }
    $id = $id -replace "'", ''
    $null = Run-Js ("window.pet.model('" + $id + "')")
    Log ('model apply: ' + $id)
}

function Show-Menu([double]$sx, [double]$sy) {
    Log ('menu open at ' + $sx + ',' + $sy)
    $cm = New-Object System.Windows.Controls.ContextMenu

    $head = New-Object System.Windows.Controls.MenuItem
    $head.Header = ('照片桌宠 3D  v' + $script:BuildVer)
    $head.IsEnabled = $false
    [void]$cm.Items.Add($head)
    [void]$cm.Items.Add((New-Object System.Windows.Controls.Separator))

    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = '换猫'
    foreach ($c in $script:CatsDoc.cats) {
        $sub = New-Object System.Windows.Controls.MenuItem
        $nm = $c.name
        if (-not $nm) { $nm = $c.id }
        if ([string]$script:S['cat'] -eq $c.id) { $sub.Header = ('* ' + $nm) } else { $sub.Header = $nm }
        $sub.Tag = $c.id
        $sub.add_Click({ param($s,$e) $script:S['cat'] = [string]$s.Tag; Apply-Coat; Save-Settings })
        [void]$mi.Items.Add($sub)
    }
    [void]$cm.Items.Add($mi)

    $miRand = New-Object System.Windows.Controls.MenuItem
    $miRand.Header = '随机制一只猫（自动配色）'
    $miRand.add_Click({ param($s,$e) New-RandomCat })
    [void]$cm.Items.Add($miRand)

    $miPal = New-Object System.Windows.Controls.MenuItem
    $miPal.Header = '自由配色…'
    $miPal.add_Click({ param($s,$e) Open-Palette })
    [void]$cm.Items.Add($miPal)

    $miModel = New-Object System.Windows.Controls.MenuItem
    $miModel.Header = '外观 → 真猫模型'
    $subCart = New-Object System.Windows.Controls.MenuItem
    $subCart.Header = '卡通猫（默认）'
    $subCart.add_Click({ param($s,$e) $script:S['model'] = 'none'; Apply-Model; Save-Settings; Set-Bubble '换回卡通猫啦' })
    [void]$miModel.Items.Add($subCart)
    foreach ($mm in (Get-Models)) {
        $subM = New-Object System.Windows.Controls.MenuItem
        if ([string]$script:S['model'] -eq $mm.id) { $subM.Header = ('* ' + $mm.name) } else { $subM.Header = $mm.name }
        $subM.Tag = $mm.id
        $subM.add_Click({ param($s,$e) $script:S['model'] = [string]$s.Tag; Apply-Model; Save-Settings; Set-Bubble ('真猫上线：' + $script:S['model']) })
        [void]$miModel.Items.Add($subM)
    }
    [void]$cm.Items.Add($miModel)
    $miKill = New-Object System.Windows.Controls.MenuItem
    $miKill.Header = '清除小猫'
    $miKill.add_Click({ param($s,$e) Clear-Kittens; Set-Bubble '小猫都送回家了' })
    [void]$cm.Items.Add($miKill)

    $mi2 = New-Object System.Windows.Controls.MenuItem
    $mi2.Header = '大小'
    foreach ($pair in @(@('小 -', -0.1), @('大 +', 0.1), @('重置', 0.9))) {
        $sub = New-Object System.Windows.Controls.MenuItem
        $sub.Header = $pair[0]; $sub.Tag = $pair[1]
        $sub.add_Click({ param($s,$e)
            $v = [double]$script:S['scale'] + [double]$s.Tag
            if ($v -lt 0.4) { $v = 0.4 }; if ($v -gt 2.4) { $v = 2.4 }
            Resize-Pet $v; Save-Settings })
        [void]$mi2.Items.Add($sub)
    }
    [void]$cm.Items.Add($mi2)

    $mi3 = New-Object System.Windows.Controls.MenuItem
    $mi3.Header = '透明度'
    foreach ($pair in @(@('更透明', -0.15), @('更清晰', 0.15), @('不透明', 1.0))) {
        $sub = New-Object System.Windows.Controls.MenuItem
        $sub.Header = $pair[0]; $sub.Tag = $pair[1]
        $sub.add_Click({ param($s,$e)
            $v = [double]$script:S['opacity']
            if ([double]$s.Tag -ge 1) { $v = 1.0 } else { $v = $v + [double]$s.Tag }
            if ($v -lt 0.25) { $v = 0.25 }; if ($v -gt 1.0) { $v = 1.0 }
            $script:S['opacity'] = $v; Apply-Opacity; Save-Settings })
        [void]$mi3.Items.Add($sub)
    }
    [void]$cm.Items.Add($mi3)

    foreach ($entry in @(@('置顶', 'topmost'), @('鼠标穿透', 'click'), @('摆饭碗', 'bowl'), @('到处走动（巡逻）', 'patrol'))) {
        $tog = New-Object System.Windows.Controls.MenuItem
        $cur = [bool]$script:S[$entry[1]]
        if ($cur) { $tog.Header = ('✓ ' + $entry[0]) } else { $tog.Header = $entry[0] }
        $tog.Tag = $entry[1]
        $tog.add_Click({ param($s,$e)
            $k = [string]$s.Tag
            $script:S[$k] = -not [bool]$script:S[$k]
            if ($k -eq 'topmost') { $win.Topmost = [bool]$script:S[$k] }
            if ($k -eq 'bowl') { Apply-Bowl }
            if ($k -eq 'click') { Toggle-ClickThrough ([bool]$script:S[$k]) }
            if ($k -eq 'patrol' -and -not [bool]$script:S['patrol']) { Stop-Walk }
            Save-Settings })
        [void]$cm.Items.Add($tog)
    }

    $feed = New-Object System.Windows.Controls.MenuItem
    $feed.Header = '喂食 +8'
    $feed.add_Click({ param($s,$e) Feed-Pet 8 })
    [void]$cm.Items.Add($feed)

    $soc = New-Object System.Windows.Controls.MenuItem
    $soc.Header = '联机'
    $sc1 = New-Object System.Windows.Controls.MenuItem
    $sc1.Header = '连接…'
    $sc1.add_Click({ param($s,$e)
        $r = [string]$script:S['socialRoom']
        $n = ([string]$script:S['socialNick']) -replace "'", ''
        $null = Run-Js ("window.pet.link('" + ($r -replace "'", '') + "','" + $n + "')")
    })
    [void]$soc.Items.Add($sc1)
    $sc0 = New-Object System.Windows.Controls.MenuItem
    $sc0.Header = '怎么联机…'
    $sc0.add_Click({ param($s,$e)
        $txt = "1) 两台电脑都运行本桌宠（不用联网注册）`n2) 右键 → 联机 → 连接…，两边填同一个 6 位房号，例如 482101`n3) 昵称各填一个不一样的名字，例如 catA / catB`n4) 连上后对方会提示 某某来了，这时可以说话、拥抱、请对方生小猫`n5) 房号只用数字，自己随便编，两边一样就行"
        [void][System.Windows.MessageBox]::Show($txt, ('照片桌宠 联机说明 v' + $script:BuildVer)) })
    [void]$soc.Items.Add($sc0)
    $sc2 = New-Object System.Windows.Controls.MenuItem
    $sc2.Header = '断开'
    $sc2.add_Click({ param($s,$e) $null = Run-Js 'window.pet.socialDisconnect()'; $script:SocialOn = $false; Set-Bubble '已断开' })
    [void]$soc.Items.Add($sc2)
    $sc3 = New-Object System.Windows.Controls.MenuItem
    $sc3.Header = '状态'
    $sc3.add_Click({ param($s,$e) if ($script:SocialOn) { Set-Bubble ('联机中 房间 ' + $script:S['socialRoom'] + ' 昵称 ' + $script:S['socialNick']) } else { Set-Bubble '当前未联机' } })
    [void]$soc.Items.Add($sc3)
    $sc6 = New-Object System.Windows.Controls.MenuItem
    $sc6.Header = '网络自检…'
    $sc6.add_Click({ param($s,$e)
        $null = Run-Js 'window.pet.selftest && window.pet.selftest()'
        Set-Bubble '正在自检发布/接收通道…' })
    [void]$soc.Items.Add($sc6)
    $soc4 = New-Object System.Windows.Controls.MenuItem
    $soc4.Header = '说句话…'
    $soc4.add_Click({ param($s,$e)
        $t = Ask-Text '说话' '说点什么（对方会用气泡显示）' '喵~'
        if ($t) { Social-Send @{ type = 'talk'; text = $t; cat = $script:SelfCoat }; Set-Bubble ('你：' + $t) } })
    [void]$soc.Items.Add($soc4)
    [void]$cm.Items.Add($soc)

    # ---------- 互动（一级菜单） ----------
    $act = New-Object System.Windows.Controls.MenuItem
    $act.Header = '互动'

    $act1 = New-Object System.Windows.Controls.MenuItem
    $act1.Header = '抱抱我好不好'
    $act1.add_Click({ param($s,$e)
        if ($script:HugNo -ge 2) {
            Social-Send @{ type = 'hug_request'; pout = 1; cat = $script:SelfCoat }
            Set-Bubble '（撒娇）就抱一下嘛～'
        } else {
            Social-Send @{ type = 'hug_request'; cat = $script:SelfCoat }
        } })
    [void]$act.Items.Add($act1)

    $act2 = New-Object System.Windows.Controls.MenuItem
    $act2.Header = '偷偷抱一下'
    $act2.add_Click({ param($s,$e) Social-Send @{ type = 'hug'; cat = $script:SelfCoat }; Set-Bubble ('我抱了 ' + (Last-Peer)) })
    [void]$act.Items.Add($act2)

    $act3 = New-Object System.Windows.Controls.MenuItem
    $act3.Header = '一起养只小猫'
    $act3.add_Click({ param($s,$e) Social-Send @{ type = 'breed'; cat = $script:SelfCoat }; Set-Bubble '问它要不要一起养只小猫……' })
    [void]$act.Items.Add($act3)

    [void]$cm.Items.Add($act)

    $miHome = New-Object System.Windows.Controls.MenuItem
    $miHome.Header = '回到右下角'
    $miHome.add_Click({ param($s,$e)
        $win.Left = $wa.Right - $win.Width - 40
        $win.Top = $wa.Bottom - $win.Height - 60
        $script:S['x'] = $win.Left; $script:S['y'] = $win.Top; Save-Settings })
    [void]$cm.Items.Add($miHome)

    [void]$cm.Items.Add((New-Object System.Windows.Controls.Separator))

    $quit = New-Object System.Windows.Controls.MenuItem
    $quit.Header = '退出'
    $quit.add_Click({ param($s,$e)
        $script:S['x'] = $win.Left; $script:S['y'] = $win.Top; Save-Settings
        $win.Close() })
    [void]$cm.Items.Add($quit)

    $cm.PlacementTarget = $win
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
    $cm.IsOpen = $true
    Log ("menu opened at " + $sx + "," + $sy)
}

# ---------- click-through ----------
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinApi {
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinChild {
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, Proc cb, IntPtr l);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  public delegate bool Proc(IntPtr h, IntPtr l);
  public static void Clear(IntPtr root, bool on) {
    EnumChildWindows(root, delegate(IntPtr h, IntPtr l) {
      int ex = GetWindowLong(h, -20);
      int want = on ? (ex | 0x20) : (ex & ~0x20);
      if (want != ex) { SetWindowLong(h, -20, want); }
      return true;
    }, IntPtr.Zero);
  }
}
"@
function Toggle-ClickThrough([bool]$on) {
    $hw = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $ex = [WinApi]::GetWindowLong($hw, -20)
    if ($on) { $ex = $ex -bor 0x20 } else { $ex = $ex -band (-bnot 0x20) }
    [void][WinApi]::SetWindowLong($hw, -20, $ex)
    Log "clickThrough=$on"
}

# ---------- webview wiring ----------
$wv.add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) { Log "wv init fail: $($e.InitializationException.Message)"; return }
    $script:Core = $s.CoreWebView2
    $script:Core.Settings.AreDefaultContextMenusEnabled = $false
    $script:Core.Settings.IsStatusBarEnabled = $false
    $script:Core.Settings.IsZoomControlEnabled = $false
    $script:Core.Settings.AreDevToolsEnabled = $false
    # 外观包（模型）目录映射成 https://packs.local，页面才能 fetch 本地模型包（避免 file:// 跨域）
    try {
        $packsDir = Join-Path $Root 'runtime\packs'
        if (-not (Test-Path $packsDir)) { New-Item -ItemType Directory -Force -Path $packsDir | Out-Null }
        $script:Core.SetVirtualHostNameToFolderMapping('packs.local', $packsDir, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
        Log ('vhost packs.local -> ' + $packsDir)
    } catch { Log ('vhost fail: ' + $_.Exception.Message) }
    $script:PageFile = 'cat.html'
    $script:UsingHotPage = $false
    $hotPagePath = Join-Path $Root 'cat3d\cat.hot.html'
    if (Test-Path $hotPagePath) { $script:PageFile = 'cat.hot.html'; $script:UsingHotPage = $true; Log 'page: using hot page' }
    $htmlPath = Join-Path $Root ('cat3d\' + $script:PageFile)
    $url = 'file:///' + ($htmlPath -replace '\\', '/') + '?coat=' + [Uri]::EscapeDataString([string]$script:S['cat']) + '&sleep=' + [string]([double]$script:S['sleepMinutes'] + 0)
    Log ("navigate: " + $url)
    $script:Core.Navigate($url)
    $script:HotPageGuard = New-Object System.Windows.Threading.DispatcherTimer
    $script:HotPageGuard.Interval = [TimeSpan]::FromSeconds(12)
    $script:HotPageGuard.add_Tick({
        $script:HotPageGuard.Stop()
        if ($script:Ready) { return }
        if (-not $script:UsingHotPage) { return }
        try {
            $hp = Join-Path $Root 'cat3d\cat.hot.html'
            if (Test-Path $hp) { Move-Item $hp (Join-Path $Root 'cat3d\cat.hot.bad.html') -Force }
        } catch { }
        $script:UsingHotPage = $false
        $script:PageFile = 'cat.html'
        Log 'page: hot page failed, rollback to bundled'
        $u2 = 'file:///' + ((Join-Path $Root 'cat3d\cat.html') -replace '\\', '/') + '?coat=' + [Uri]::EscapeDataString([string]$script:S['cat']) + '&sleep=' + [string]([double]$script:S['sleepMinutes'] + 0)
        $script:Core.Navigate($u2)
    })
    $script:HotPageGuard.Start()
        Log 'wv init ok'
})

$wv.add_NavigationCompleted({
    param($s, $e)
    Log ("nav completed: " + $e.IsSuccess + " status=" + $e.WebErrorStatus)
})

$wv.add_WebMessageReceived({
    param($s, $e)
    try {
        $m = $e.WebMessageAsJson | ConvertFrom-Json
    } catch { return }
    switch ($m.t) {
        'ready' {
            Log 'msg: ready'
            $script:Ready = $true
            if ($script:HotPageGuard) { $script:HotPageGuard.Stop() }
            $script:PanelOn = $false
$script:DragIdle = 0
            Apply-Coat
            Apply-Opacity
            Apply-Bowl
            $null = Run-Js "window.pet.layout('$($script:S['layout'])')"
            Apply-RestCfg
            Apply-PackLook
            Apply-Model
            Log 'page ready'
        }
        'kn' { Log ('keys_total: ' + $m.n + ' chips: ' + $m.c) }
        'hit' { Log 'msg: click' }
        'md' {
            $script:DragFrom = @{ x = [double]$m.x; y = [double]$m.y; left = $win.Left; top = $win.Top }
        }
        'mm' {
            if ($script:DragFrom) {
                $win.Left = $script:DragFrom.left + ([double]$m.x - $script:DragFrom.x)
                $win.Top = $script:DragFrom.top + ([double]$m.y - $script:DragFrom.y)
            }
        }
        'mu' {
            if ($script:DragFrom -and [bool]$m.moved) {
                $script:S['x'] = $win.Left; $script:S['y'] = $win.Top; Save-Settings
            }
            $script:DragFrom = $null
        }
        'panel' { $script:PanelOn = [bool]$m.on }
        'palcancel' { Apply-Coat; Set-Bubble '配色已还原' }
        'newcat' {
            try {
                $src = $m.cat
                $n = 1
                foreach ($x in $script:CatsDoc.cats) { if ([string]$x.id -like 'user-*') { $n++ } }
                $id = 'user-' + (Get-Random -Minimum 100000 -Maximum 999999)
                while (Get-CatById $id) { $id = 'user-' + (Get-Random -Minimum 100000 -Maximum 999999) }
                $name = '我的猫' + $n
                $obj = [pscustomobject]@{
                    id = $id; kind = 'custom'; name = $name
                    fur = [string]$src.fur; patch = [string]$src.patch; accent = [string]$src.accent
                    eye = [string]$src.eye; eye2 = [string]$src.eye2; pattern = [string]$src.pattern
                    spots = @()
                }
                $script:CatsDoc.cats = @($script:CatsDoc.cats) + @($obj)
                Save-Cats
                $script:S['cat'] = $id
                Save-Settings
                Apply-Coat
                Set-Bubble ('配色保存好啦：' + $name)
                Log ('newcat ' + $id + ' ' + $name + ' fur=' + $obj.fur + ' patch=' + $obj.patch + ' pattern=' + $obj.pattern)
            } catch { Log ('newcat ERR: ' + $_.Exception.Message); Set-Bubble '保存失败，稍后再试' }
        }
        'link' {
            $room = ([string]$m.room) -replace '[^0-9]', ''
            $nick = [string]$m.nick
            if (-not $nick) { $nick = 'pet' }
            if ($room.Length -ne 6) { Set-Bubble '房号要 6 位数字'; return }
            $script:S['socialRoom'] = $room
            $script:S['socialNick'] = $nick
            Save-Settings
            $null = Run-Js ("window.pet.socialConnect('" + $room + "','" + ($nick -replace "'", '') + "')")
            Set-Bubble ('正在连接 房间 ' + $room)
            Log ('link start ' + $room + ' ' + $nick)
        }
        'menu' { Log 'msg: menu'; try { Show-Menu ([double]$m.x) ([double]$m.y) } catch { Log ('menu ERR: ' + $_.Exception.GetType().Name + ' ' + $_.Exception.Message) } }
        'askdone' {
            if ([string]$m.kind -eq 'breed' -and [bool]$m.ok) {
                # 被邀请方：同意后本机也按双方毛色生一只，这样两边都有小猫、都播动画
                Set-Bubble '答应一起养只小猫啦'
                try { Breed-Kitten $script:PeerCoat } catch { Log ('breed(acceptor) fail: ' + $_.Exception.Message) }
            }
            elseif ([string]$m.kind -eq 'hug' -and [bool]$m.ok) { Show-HugPair $script:PeerCoat }
            else { Set-Bubble '你拒绝了' }
        }
        'social' {
            $ev = [string]$m.ev
            if ($ev -eq 'state') {
                $script:SocialOn = [bool]$m.ok
                if ($script:SocialOn) { Set-Bubble ('联机已连接 房间 ' + $m.room + ' 昵称 ' + $m.nick) }
                elseif ([string]$m.m) { Set-Bubble ('联机失败 ' + $m.m) }
                else { Set-Bubble '联机已断开' }
                Log ('social state ok=' + $m.ok + ' m=' + $m.m)
            } elseif ($ev -eq 'msg') {
                $d = $m.data
                $from = [string]$d.from
                switch ([string]$d.type) {
                    'hello' { $script:Peers[$from] = (Get-Date); Set-Bubble ($from + ' 来了') }
                    'ping' { }
                    'hug_request' {
                        $extra = ' 想拥抱一下'
                        if ($d.pout) { $extra = ' 已经被你拒绝两次啦，就抱一下嘛～' }
                        $je = ConvertTo-Json $extra -Compress
                        $script:PeerCoat = $d.cat
                        $null = Run-Js ("window.pet.ask('hug','" + $from + "'," + $je + ")")
                        Log ('hug request from ' + $from + ' pout=' + $d.pout)
                    }
                    'hug_no' { $script:HugNo = $script:HugNo + 1; Set-Bubble ($from + ' 这次没同意') }
                    'breed_no' { Set-Bubble ($from + ' 说下次吧') }
                    'talk' { Show-Guest $d.cat ([string]$from + '：' + [string]$d.text) 'talk' }
                    'breed_ok' {
                        # 只有发起方在这里生小猫；被申请方只回一个自己的毛色，避免两边重复生
                        if ($d.cat) {
                            Set-Bubble ('答应了，小猫来了～')
                            Breed-Kitten $d.cat
                        } else { Set-Bubble '拿不到对方的毛色，请对方再点一次' }
                    }
                    'hug' {
                        if (-not $d.re) {
                            Set-Bubble ($from + ' 抱了你一下')
                            Show-HugPair $d.cat
                        } else {
                            Set-Bubble ('我抱了 ' + $from)
                            $script:HugNo = 0
                            Show-HugPair $d.cat
                        }
                    }
                    'feed' { Feed-Pet 4; Set-Bubble ($from + ' 喂了你一口') }
                    'breed' {
                        $script:PeerCoat = $d.cat
                        $null = Run-Js ("window.pet.ask('breed','" + $from + "')")
                        Log ('breed request from ' + $from)
                    }
                }
                Log ('social msg ' + $d.type + ' from ' + $from)
            } elseif ($ev -eq 'selftest') {
                $http = [int]$m.http
                $sse = [int]$m.sse
                $stateTxt = switch ($sse) { 0 { '建立中' } 1 { '已连接' } 2 { '断开/重连中' } default { '未启动' } }
                if ($http -eq 200) { Set-Bubble ('自检 发布正常 接收 ' + $stateTxt + ' 房间 ' + $m.room) }
                elseif ($http -eq 429) { Set-Bubble ('自检 被限流 429，过几分钟再试 接收 ' + $stateTxt) }
                elseif ($http -gt 0) { Set-Bubble ('自检 发布返回 ' + $http + ' 接收 ' + $stateTxt) }
                else { Set-Bubble ('自检 发不出去，网络不通 接收 ' + $stateTxt) }
                Log ('selftest http=' + $http + ' sse=' + $sse + ' room=' + $m.room + ' nick=' + $m.nick)
            } elseif ($ev -eq 'err') { Log ('social err ' + $m.m); Set-Bubble ('联机出错：' + $m.m) }
        }
        'err' { Log ("page error: " + $m.m) }
    }
})

# ---------- command bus (MCP / scripts) ----------
$CmdPath = Join-Path $Runtime 'command.json'
$AckPath = Join-Path $Runtime 'ack.json'
$script:LastSeq = -1
$bus = New-Object System.Windows.Threading.DispatcherTimer
$bus.Interval = [TimeSpan]::FromMilliseconds(250)
$bus.add_Tick({
    if (-not (Test-Path $CmdPath)) { return }
    try { $cmd = Get-Content $CmdPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if (-not $cmd) { return }
    if ([int]$cmd.seq -le $script:LastSeq) { return }
    $script:LastSeq = [int]$cmd.seq
    $action = [string]$cmd.action
    $a = $cmd.args
    Log ('bus: ' + $action + ' seq=' + $cmd.seq)
    $result = $null
    try {
        switch ($action) {
            'ping' { $result = 'pong' }
            'list_cats' { $result = @($script:CatsDoc.cats | ForEach-Object { @{ id = $_.id; name = $_.name; kind = $_.kind } }) }
            'get_state' { $result = @{ cat = $script:S['cat']; scale = $script:S['scale']; opacity = $script:S['opacity']; food = $script:S['food']; bowl = $script:S['bowl']; x = $win.Left; y = $win.Top; ready = $script:Ready } }
            'switch_cat' { if ($a.id) { $script:S['cat'] = [string]$a.id; Apply-Coat; Save-Settings }; $result = 'ok' }
            'set_scale' { if ($a.scale) { Resize-Pet ([double]$a.scale); Save-Settings }; $result = 'ok' }
            'set_opacity' { if ($a.opacity) { $script:S['opacity'] = [double]$a.opacity; Apply-Opacity; Save-Settings }; $result = 'ok' }
            'feed' { $amt = 8; if ($a.amount) { $amt = [int]$a.amount }; Feed-Pet $amt; $result = 'ok' }
            'breed' { Breed-Kitten $null; $result = 'ok' }
            'rand_cat' { New-RandomCat; $result = 'ok' }
            'bowl' { $script:S['bowl'] = [bool]$a.on; Apply-Bowl; Save-Settings; $result = 'ok' }
            'say' { Set-Bubble ([string]$a.text); $result = 'ok' }
            'move_to' { if ($a.x) { $win.Left = [double]$a.x }; if ($a.y) { $win.Top = [double]$a.y }; $result = 'ok' }
        'walk' { Stop-Walk; Start-Walk ([double]($a.dist)); $result = 'ok' }
        'walk_stop' { Stop-Walk; $result = 'ok' }
        'patrol' { $script:S['patrol'] = [bool]$a.on; if (-not [bool]$script:S['patrol']) { Stop-Walk }; Save-Settings; $result = 'ok' }
            'set_always_on_top' { $script:S['topmost'] = [bool]$a.on; $win.Topmost = [bool]$a.on; Save-Settings; $result = 'ok' }
            'set_click_through' { $script:S['clickThrough'] = [bool]$a.on; Toggle-ClickThrough ([bool]$a.on); Save-Settings; $result = 'ok' }
            'tap' { $null = Run-Js "window.pet.tap('$([string]$a.side)')"; $result = 'ok' }
            'social_connect' {
                $room = ([string]$a.room) -replace '[^0-9]', ''
                $nick = ([string]$a.nick) -replace "'", ''
                if ($room.Length -eq 6) {
                    $script:S['socialRoom'] = $room; $script:S['socialNick'] = $nick; Save-Settings
                    $null = Run-Js "window.pet.socialConnect('$room','$nick')"
                    $result = 'ok'
                } else { $result = @{ error = 'room must be 6 digits' } }
            }
            'social_send' { Social-Send @{ type = [string]$a.type; to = [string]$a.to }; $result = 'ok' }
            'eval' { $null = Run-Js ([string]$a.js); $result = 'ok' }
            'hot' { Update-Packs; $result = 'ok' }
            'palette' { Open-Palette; $result = 'ok' }
            'model' { $script:S['model'] = [string]$a.id; Apply-Model; Save-Settings; $result = 'ok' }
            'clear_kittens' { Clear-Kittens; $result = 'ok' }
            'menu' { Show-Menu ([double]$a.x) ([double]$a.y); $result = 'ok' }
            'social_off' { $null = Run-Js 'window.pet.socialDisconnect()'; $script:SocialOn = $false; $result = 'ok' }
            default { $result = @{ error = ('unknown action ' + $action) } }
        }
    } catch {
        $result = @{ error = $_.Exception.Message }
    }
    @{ seq = $cmd.seq; ok = $true; result = $result } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $AckPath -Encoding UTF8
})

# ---------- show ----------
$win.add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DwmApi {
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
}
"@
function Set-PerPixelAlpha {
    try {
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        if ($hw -eq [IntPtr]::Zero) { return }
        $mg = New-Object DwmApi+MARGINS
        $mg.l = -1; $mg.r = -1; $mg.t = -1; $mg.b = -1
        [void][DwmApi]::DwmExtendFrameIntoClientArea($hw, [ref]$mg)
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hw)
        if ($src) { $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent }
    } catch { Log ("dwm fail: " + $_.Exception.Message) }
}
$win.Show()
Set-PerPixelAlpha
$bus.Start()
try {
    $kat = New-Object System.Windows.Threading.DispatcherTimer
    $kat.Interval = [TimeSpan]::FromMilliseconds(1500)
    $kat.add_Tick({ $kat.Stop(); try { Apply-Kittens } catch { Log ('kittens fail: ' + $_.Exception.Message) } })
    $kat.Start()
} catch { Log ('kittens timer fail: ' + $_.Exception.Message) }

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.add_Tick({
    $timer.Stop()
    try { $null = $wv.EnsureCoreWebView2Async($null) } catch { Log "ensure fail: $($_.Exception.Message)" }
})
$timer.Start()

Log "pet3d started, cat=$($script:S['cat']) scale=$($script:S['scale'])"


# ================= 托盘图标 / 全局输入同步 / 热更新 =================

$InteropCode = @"
using System;
using System.Runtime.InteropServices;
public class PetHooks {
    public const int MAX = 256;
    public struct POINT { public int x; public int y; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, KeyHookProc fn, IntPtr mod, int thread);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, MouseHookProc fn, IntPtr mod, int thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, ref KBDLLHOOKSTRUCT d);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, ref MSLLHOOKSTRUCT d);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    // 左键是否真的还按着：防止 hook 漏掉 mouseup 导致拖动状态一直挂着
    public static bool LeftHeld() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
    struct KBDLLHOOKSTRUCT { public int vk, scan, flags, time; public IntPtr extra; }
    struct MSLLHOOKSTRUCT { public POINT pt; public int data, flags, time; public IntPtr extra; }
    delegate IntPtr KeyHookProc(int nCode, IntPtr wParam, ref KBDLLHOOKSTRUCT data);
    delegate IntPtr MouseHookProc(int nCode, IntPtr wParam, ref MSLLHOOKSTRUCT data);
    static IntPtr hkKey = IntPtr.Zero, hkMouse = IntPtr.Zero;
    static KeyHookProc kp; static MouseHookProc mp;
    static System.Collections.Generic.List<int> hits = new System.Collections.Generic.List<int>(64);
    static System.Collections.Generic.List<int> btns = new System.Collections.Generic.List<int>(32);
    static object sync = new object();
    static volatile int mx = 0, my = 0;
    static volatile bool hasPos = false;
    public static bool StartKeyboard() {
        if (hkKey != IntPtr.Zero) return true;
        kp = HookKey;
        hkKey = SetWindowsHookEx(13, kp, IntPtr.Zero, 0);
        return hkKey != IntPtr.Zero;
    }
    public static bool StartMouse() {
        if (hkMouse != IntPtr.Zero) return true;
        mp = HookMouse;
        hkMouse = SetWindowsHookEx(14, mp, IntPtr.Zero, 0);
        return hkMouse != IntPtr.Zero;
    }
    public static void StopAll() {
        if (hkKey != IntPtr.Zero) { UnhookWindowsHookEx(hkKey); hkKey = IntPtr.Zero; }
        if (hkMouse != IntPtr.Zero) { UnhookWindowsHookEx(hkMouse); hkMouse = IntPtr.Zero; }
    }
    static IntPtr HookKey(int n, IntPtr w, ref KBDLLHOOKSTRUCT d) {
        try {
            if (n == 0) {
                int msg = (int)w;
                int vk = d.vk;
                if ((msg == 0x100 || msg == 0x104) && vk > 0 && vk < MAX) {
                    lock (sync) { if (hits.Count < 64) hits.Add(vk); }
                }
            }
        } catch { }
        return CallNextHookEx(hkKey, n, w, ref d);
    }
    static IntPtr HookMouse(int n, IntPtr w, ref MSLLHOOKSTRUCT d) {
        try {
            if (n == 0) {
                int msg = (int)w;
                mx = d.pt.x; my = d.pt.y; hasPos = true;
                int type = -1;
                if (msg == 0x201) type = 0;          // left down
                else if (msg == 0x202) type = 1;     // left up
                else if (msg == 0x204) type = 2;     // right down
                else if (msg == 0x205) type = 3;     // right up
                if (type >= 0) { lock (sync) { if (btns.Count < 90) { btns.Add(type); btns.Add(d.pt.x); btns.Add(d.pt.y); } } }
            }
        } catch { }
        return CallNextHookEx(hkMouse, n, w, ref d);
    }
    public static int[] PollButtons() {
        int[] got = null;
        lock (sync) {
            if (btns.Count == 0) return null;
            got = btns.ToArray();
            btns.Clear();
        }
        return got;
    }
    public static bool GetPoint(out int x, out int y) {
        POINT p;
        if (GetCursorPos(out p)) { mx = p.x; my = p.y; hasPos = true; x = mx; y = my; return true; }
        x = mx; y = my;
        return hasPos;
    }
    static string Code(int vk) {
        if (vk >= 65 && vk <= 90) return "Key" + (char)vk;
        if (vk >= 48 && vk <= 57) return "Digit" + (char)vk;
        switch (vk) {
            case 32: return "Space";
            case 13: return "Enter";
            case 8: return "Backspace";
            case 9: return "Tab";
            case 27: return "Escape";
            case 16: return "ShiftLeft";
            case 17: return "ControlLeft";
            case 18: return "AltLeft";
            case 37: return "ArrowLeft";
            case 38: return "ArrowUp";
            case 39: return "ArrowRight";
            case 40: return "ArrowDown";
            case 186: return "Semicolon";
            case 187: return "Equal";
            case 188: return "Comma";
            case 189: return "Minus";
            case 190: return "Period";
            case 191: return "Slash";
            case 192: return "Backquote";
            case 219: return "BracketLeft";
            case 220: return "Backslash";
            case 221: return "BracketRight";
        }
        return null;
    }
    public static string PollJson() {
        int[] got;
        lock (sync) {
            if (hits.Count == 0) return null;
            got = hits.ToArray();
            hits.Clear();
        }
        System.Text.StringBuilder sb = new System.Text.StringBuilder("[");
        int n = 0;
        for (int i = 0; i < got.Length; i++) {
            string c = Code(got[i]);
            if (c == null) continue;
            if (n > 0) sb.Append(',');
            n++;
            sb.Append('"').Append(c).Append('"');
        }
        sb.Append(']');
        if (n == 0) return null;
        return sb.ToString();
    }
}
"@
Add-Type -TypeDefinition $InteropCode -Language CSharp

function VkToCode([int]$vk) {
    if ($vk -ge 65 -and $vk -le 90) { return 'Key' + [char]$vk }
    if ($vk -ge 48 -and $vk -le 57) { return 'Digit' + [char]$vk }
    switch ($vk) {
        32 { 'Space' } 13 { 'Enter' } 8 { 'Backspace' } 9 { 'Tab' } 27 { 'Escape' }
        16 { 'ShiftLeft' } 17 { 'ControlLeft' } 18 { 'AltLeft' }
        37 { 'ArrowLeft' } 38 { 'ArrowUp' } 39 { 'ArrowRight' } 40 { 'ArrowDown' }
        186 { 'Semicolon' } 187 { 'Equal' } 188 { 'Comma' } 189 { 'Minus' } 190 { 'Period' } 191 { 'Slash' }
        192 { 'Backquote' } 219 { 'BracketLeft' } 220 { 'Backslash' } 221 { 'BracketRight' }
        96 { 'Numpad0' } 97 { 'Numpad1' } 98 { 'Numpad2' } 99 { 'Numpad3' } 100 { 'Numpad4' }
        101 { 'Numpad5' } 102 { 'Numpad6' } 103 { 'Numpad7' } 104 { 'Numpad8' } 105 { 'Numpad9' }
        default { 'Key' + [char]([Math]::Min(90, [Math]::Max(65, ($vk % 26) + 65))) }
    }
}

$script:KeyState = $null
$script:LastMouseSend = 0
$script:LastMouseX = -9999
$script:LastMouseY = -9999

$script:Regions = @(
    @(0.364, 0.0181, 0.272, 0.4574),
    @(0.335, 0.1236, 0.330, 0.7399),
    @(0.510, 0.4830, 0.286, 0.3753),
    @(0.280, 0.7495, 0.539, 0.2506),
    @(0.183, 0.7686, 0.142, 0.2154)
)
$script:Ignored = $null

function Set-Ignore([bool]$on) {
    if ($script:Ignored -eq $on) { return }
    $script:Ignored = $on
    try { Toggle-ClickThrough $on } catch {}
}

$script:Regions = @(
    @(0.364, 0.0181, 0.272, 0.4574),
    @(0.335, 0.1236, 0.330, 0.7399),
    @(0.510, 0.4830, 0.286, 0.3753),
    @(0.280, 0.7495, 0.539, 0.2506),
    @(0.183, 0.7686, 0.142, 0.2154)
)
$script:Ignored = $null

function Set-Ignore([bool]$on) {
    if ($script:Ignored -eq $on) { return }
    $script:Ignored = $on
    try { Toggle-ClickThrough $on } catch {}
}

$script:Regions = @(
    @(0.364, 0.0181, 0.272, 0.4574),
    @(0.335, 0.1236, 0.330, 0.7399),
    @(0.510, 0.4830, 0.286, 0.3753),
    @(0.280, 0.7495, 0.539, 0.2506),
    @(0.183, 0.7686, 0.142, 0.2154)
)
$script:Ignored = $null

function Set-Ignore([bool]$on) {
    if ($script:Ignored -eq $on) { return }
    $script:Ignored = $on
    try { Toggle-ClickThrough $on } catch {}
}

$script:Regions = @(
    @(0.364, 0.0181, 0.272, 0.4574),
    @(0.335, 0.1236, 0.330, 0.7399),
    @(0.510, 0.4830, 0.286, 0.3753),
    @(0.280, 0.7495, 0.539, 0.2506),
    @(0.183, 0.7686, 0.142, 0.2154)
)
$script:Ignored = $null

# 真实猫身像素遮罩（27x16，从实际画面差分得到）：只有落在猫/键盘上的点才算命中
$script:HitMask = @(
    '...........................',
    '...........................',
    '...........................',
    '..........#.####...........',
    '..........#######..........',
    '..........#.#####..........',
    '..........#######..........',
    '..........#######..........',
    '.........#########.........',
    '.........#########.........',
    '.........###########.......',
    '.........############......',
    '........###############....',
    '........###########.###....',
    '........###############....',
    '........#..................'
)

function Test-Hit([double]$rx, [double]$ry) {
    if ($rx -lt 0 -or $rx -gt 1 -or $ry -lt 0 -or $ry -gt 1) { return $false }
    $col = [int][Math]::Floor($rx * 27); $row = [int][Math]::Floor($ry * 16)
    if ($col -lt 0) { $col = 0 }; if ($col -gt 26) { $col = 26 }
    if ($row -lt 0) { $row = 0 }; if ($row -gt 15) { $row = 15 }
    $line = [string]$script:HitMask[$row]
    if ($line[$col] -ne '.') { return $true }
    foreach ($dr in @(-1,0,1)) {
        foreach ($dc in @(-1,0,1)) {
            $r2 = $row + $dr; $c2 = $col + $dc
            if ($r2 -lt 0 -or $r2 -gt 15 -or $c2 -lt 0 -or $c2 -gt 26) { continue }
            $l2 = [string]$script:HitMask[$r2]
            if ($l2[$c2] -ne '.') { return $true }
        }
    }
    return $false
}

function Set-Ignore([bool]$on) {
    if ($script:Ignored -eq $on) { return }
    $script:Ignored = $on
    try { Toggle-ClickThrough $on } catch {}
}

function Start-GlobalInput {
    $ok1 = [PetHooks]::StartKeyboard()
    $ok2 = [PetHooks]::StartMouse()
    Log ("global keyboard hook: " + $ok1 + " mouse hook: " + $ok2)

    # 每个按键只弹出字母 chip，指甲按在对应键上 210ms 后松开
    $script:KeyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:KeyTimer.Interval = [TimeSpan]::FromMilliseconds(60)
    $script:KeyTimer.add_Tick({
        try {
            $json = [PetHooks]::PollJson()
            if ($json) { $null = Run-Js ('window.pet.input({kind:"press",list:' + $json + '})') }
        } catch {}
    })
    $script:KeyTimer.Start()

    # 30ms：跟光标 + 按原版逻辑做命中区域点击穿透
    $script:LastPx = -9999
    $script:LastPy = -9999
    $script:MouseTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:MouseTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:MouseTimer.add_Tick({
        try {
            if ($win.Visibility -ne 'Visible') { return }
            $mx = 0; $my = 0
            if (-not [PetHooks]::GetPoint([ref]$mx, [ref]$my)) { return }
            $w = $win.ActualWidth; $h = $win.ActualHeight
            if ($w -le 1 -or $h -le 1) { return }
            # 左键早就松开了却还挂着拖动状态（hook 漏 up 事件）→ 立刻清掉，
            # 否则 $over 会一直为真，全屏点哪里都像点在猫身上
            if ($script:HostDrag) {
                if ([PetHooks]::LeftHeld()) { $script:DragIdle = 0 }
                else {
                    $script:DragIdle++
                    if ($script:DragIdle -ge 3) {
                        Log 'drag stale cleared'
                        $script:HostDrag = $null
                        $script:DragIdle = 0
                    }
                }
            } else { $script:DragIdle = 0 }

            # 先算是否落在猫身上，鼠标事件由宿主自己判定，不依赖 WebView2 是否收到
            $rx = ($mx - $win.Left) / $w
            $ry = ($my - $win.Top) / $h
            $inside = ($rx -ge 0 -and $rx -le 1 -and $ry -ge 0 -and $ry -le 1)
            $over = $false
            if ($inside) { $over = (Test-Hit $rx $ry) }
            if ($script:HostDrag) { $over = $true }
            if ($script:PanelOn) { $over = $true }

            $bt = [PetHooks]::PollButtons()
            if ($bt) {
                for ($bi = 0; $bi -lt $bt.Length; $bi += 3) {
                    $t = $bt[$bi]; $bx = $bt[$bi + 1]; $by = $bt[$bi + 2]
                    # 抬起事件一定要处理（哪怕松手时已经滑到空白处），
                    # 否则拖动状态永远挂住 → 之后全屏点哪里都算点在猫身上
                    if ($t -eq 1) {
                        if ($script:HostDrag) {
                            Log ('drag end moved=' + $script:HostDrag.moved)
                            if ($script:HostDrag.moved) {
                                $script:S['x'] = $win.Left; $script:S['y'] = $win.Top
                                Save-Settings
                            }
                        }
                        $script:HostDrag = $null
                        continue
                    }
                    if (-not $over) { continue }
                    if ($t -eq 2) { Show-Menu ([double]$bx) ([double]$by) }
                    elseif ($t -eq 0) {
                        $script:HostDrag = @{ x = $mx; y = $my; left = $win.Left; top = $win.Top; moved = $false }
                        Log ('drag start ' + $bx + ',' + $by)
                    }
                }
            }
            if ($script:HostDrag) {
                $dx = $mx - $script:HostDrag.x; $dy = $my - $script:HostDrag.y
                if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 3) { $script:HostDrag.moved = $true }
                if ($script:HostDrag.moved) {
                    $win.Left = $script:HostDrag.left + $dx
                    $win.Top = $script:HostDrag.top + $dy
                }
            }
            if ($script:KittenWins.Count -gt 0 -and ($win.Left -ne $script:LastKL -or $win.Top -ne $script:LastKT)) {
                $script:LastKL = $win.Left; $script:LastKT = $win.Top
                Move-Kittens
            }

            if ([Math]::Abs($mx - $script:LastPx) + [Math]::Abs($my - $script:LastPy) -gt 2) {
                $script:LastPx = $mx; $script:LastPy = $my
                $nx = [Math]::Max(-1.0, [Math]::Min(1.0, $rx * 2 - 1))
                $ny = [Math]::Max(-1.0, [Math]::Min(1.0, $ry * 2 - 1))
                $null = Run-Js ("window.pet.pointer(" + $nx.ToString('0.000') + "," + $ny.ToString('0.000') + ")")
            }

            Set-Ignore (-not $over)
        } catch {}
    })
    $script:MouseTimer.Start()
}

# ---------- 巡逻走动：真猫迈步 + 窗口按步频平移（不是滑行） ----------
$script:Walking = $false
$script:WalkDx = 0
$script:WalkTo = 0
$script:WalkEnd = 0
$script:WalkGrow = 0
$script:WalkShift = 0
$script:WalkW0 = 0
$script:LastPatrol = 0
$script:WalkTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WalkTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$script:WalkTimer.add_Tick({
    try {
        if (-not $script:Walking) { $script:WalkTimer.Stop(); return }
        $script:WalkTo = $script:WalkTo + $script:WalkDx
        if ($script:WalkDx -gt 0) { $done = ($script:WalkTo -ge $script:WalkEnd) } else { $done = ($script:WalkTo -le $script:WalkEnd) }
        if ($done) { $win.Left = $script:WalkEnd; Stop-Walk }
        else { $win.Left = $script:WalkTo }
    } catch { Stop-Walk }
})

function Stop-Walk {
    try { if ($script:WalkTimer) { $script:WalkTimer.Stop() } } catch { }
    if ($script:Walking) {
        $script:Walking = $false
        $null = Run-Js 'window.pet.walkStop && window.pet.walkStop()'
    }
    if ($script:WalkGrow -gt 0) {
        try {
            $grow = $script:WalkGrow
            $script:WalkGrow = 0
            $win.Width = $script:WalkW0
            $win.Left = $win.Left + $script:WalkShift
        } catch { $script:WalkGrow = 0 }
    }
    try { $script:S['x'] = $win.Left; $script:S['y'] = $win.Top; Save-Settings } catch { }
}

function Start-Walk([double]$dist) {
    if ($script:Walking) { return }
    if ([string]$script:S['model'] -eq 'none') { return }
    if (-not $script:Ready) { return }
    if ($script:HostDrag) { return }
    if ($win.ActualWidth -le 1) { return }
    # 侧身走路帧比正脸宽：走路时把窗口临时加宽（多出来的是透明区，看不出来），
    # 同时左边界补半个差值，猫在屏幕上的位置不跳
    $script:WalkGrow = 0
    $script:WalkShift = 0
    $script:WalkW0 = [int]$win.Width
    $needW = [int]([Math]::Ceiling($win.ActualHeight * 1.06) + 14)
    if ($needW -gt $script:WalkW0) {
        $script:WalkShift = [Math]::Round(($needW - $script:WalkW0) / 2)
        $script:WalkGrow = $needW - $script:WalkW0
        $win.Width = $needW
        $win.Left = $win.Left - $script:WalkShift
    }
    $w = $win.ActualWidth
    if ($w -le 1) { Stop-Walk; return }
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = $win.Left
    if ($dist -le 0) { $dist = 45 + (Get-Random -Maximum 115) }
    $maxR = $wa.Right - $w - $left
    $maxL = $left - $wa.Left
    if ($maxR -lt 24 -and $maxL -lt 24) { Stop-Walk; return }
    $dir = 1
    if ((Get-Random -Maximum 2) -eq 0) { $dir = -1 }
    if ($dir -gt 0 -and $maxR -lt $dist) { $dir = -1 }
    if ($dir -lt 0 -and $maxL -lt $dist) { $dir = 1 }
    if ($dir -gt 0) { $avail = $maxR } else { $avail = $maxL }
    if ($avail -lt 20) { Stop-Walk; return }
    if ($dist -gt $avail) { $dist = [Math]::Max(20, [Math]::Floor($avail)) }
    $script:Walking = $true
    $script:WalkDx = 2.6 * $dir
    $script:WalkTo = $left
    $script:WalkEnd = $left + ($dir * $dist)
    $ms = [int](([Math]::Abs($dist) / 2.6) * 30) + 140
    $null = Run-Js ('window.pet.walk && window.pet.walk(' + $dir + ',' + $ms + ')')
    $script:WalkTimer.Start()
    Log ('walk start dir=' + $dir + ' dist=' + [int]$dist)
}

$script:PatrolTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PatrolTimer.Interval = [TimeSpan]::FromMilliseconds(6000)
$script:PatrolTimer.add_Tick({
    try {
        if (-not [bool]$script:S['patrol']) { return }
        if ($script:Walking) { return }
        if ($script:HostDrag -or $script:PanelOn -or (-not $script:Ready)) { return }
        if ($win.Visibility -ne 'Visible') { return }
        $now = [Environment]::TickCount
        if (($now - $script:LastPatrol) -lt 24000 -and $script:LastPatrol -ne 0) { return }
        # 榧犳爣鍦ㄧ尗韬笂鎴栫尗闄勮繎鏃跺厛鍒窇锛屽厤寰楃敤鎴锋姄涓嶄綇
        $mx = 0; $my = 0
        if ([PetHooks]::GetPoint([ref]$mx, [ref]$my)) {
            if ($mx -ge ($win.Left - 40) -and $mx -le ($win.Left + $win.ActualWidth + 40) -and
                $my -ge ($win.Top - 40) -and $my -le ($win.Top + $win.ActualHeight + 40)) { return }
        }
        if ((Get-Random -Maximum 100) -lt 24) {
            $script:LastPatrol = $now
            Start-Walk 0
        }
    } catch { }
})
$script:PatrolTimer.Start()










# ---------- 托盘 ----------
function New-CatIcon {
    try {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $fur = [System.Drawing.Color]::FromArgb(255, 240, 150, 60)
        $dark = [System.Drawing.Color]::FromArgb(255, 120, 70, 30)
        # ears
        $g.FillPolygon((New-Object System.Drawing.SolidBrush $fur), @(
            (New-Object System.Drawing.Point 5, 13),
            (New-Object System.Drawing.Point 8, 2),
            (New-Object System.Drawing.Point 13, 12)))
        $g.FillPolygon((New-Object System.Drawing.SolidBrush $fur), @(
            (New-Object System.Drawing.Point 19, 12),
            (New-Object System.Drawing.Point 24, 2),
            (New-Object System.Drawing.Point 27, 13)))
        # head
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $fur), 4, 9, 24, 20)
        # eyes
        $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,40,40,40))), 10, 17, 3, 4)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,40,40,40))), 19, 17, 3, 4)
        # nose
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $dark), 14, 23, 4, 3)
        $g.Dispose()
        $hicon = $bmp.GetHicon()
        $ico = [System.Drawing.Icon]::FromHandle($hicon)
        return $ico
    } catch { Log ("icon fail: " + $_.Exception.Message); return [System.Drawing.SystemIcons]::Application }
}
function Start-Tray {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = New-CatIcon
        $ni.Text = ('照片桌宠 3D v' + $script:BuildVer)
        $ni.Visible = $true

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $itVer = New-Object System.Windows.Forms.ToolStripMenuItem
        $itVer.Text = ('照片桌宠 3D  v' + $script:BuildVer)
        $itVer.Enabled = $false
        [void]$menu.Items.Add($itVer)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $itShow = New-Object System.Windows.Forms.ToolStripMenuItem
        $itShow.Text = '显示 / 隐藏'
        $itShow.add_Click({ if ($win.Visibility -eq 'Visible') { $win.Hide() } else { Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DwmApi {
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
}
"@
function Set-PerPixelAlpha {
    try {
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        if ($hw -eq [IntPtr]::Zero) { return }
        $mg = New-Object DwmApi+MARGINS
        $mg.l = -1; $mg.r = -1; $mg.t = -1; $mg.b = -1
        [void][DwmApi]::DwmExtendFrameIntoClientArea($hw, [ref]$mg)
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hw)
        if ($src) { $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent }
    } catch { Log ("dwm fail: " + $_.Exception.Message) }
}
$win.Show()
Set-PerPixelAlpha; $win.Activate() } })
        [void]$menu.Items.Add($itShow)

        $itTop = New-Object System.Windows.Forms.ToolStripMenuItem
        $itTop.Text = '置顶'
        $itTop.add_Click({ $script:S['topmost'] = -not [bool]$script:S['topmost']; $win.Topmost = [bool]$script:S['topmost']; Save-Settings })
        [void]$menu.Items.Add($itTop)

        $itPack = New-Object System.Windows.Forms.ToolStripMenuItem
        $itPack.Text = '检查更新'
        $itPack.add_Click({ Update-Packs })
        [void]$menu.Items.Add($itPack)

        $itQuit = New-Object System.Windows.Forms.ToolStripMenuItem
        $itQuit.Text = '退出'
        $itQuit.add_Click({
            try { [PetHooks]::Stop() } catch {}
            try { $script:Tray.Visible = $false } catch {}
            $win.Close()
        })
        [void]$menu.Items.Add($itQuit)

        $ni.ContextMenuStrip = $menu
        $ni.add_DoubleClick({ if ($win.Visibility -eq 'Visible') { $win.Hide() } else { Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DwmApi {
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
}
"@
function Set-PerPixelAlpha {
    try {
        $hw = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        if ($hw -eq [IntPtr]::Zero) { return }
        $mg = New-Object DwmApi+MARGINS
        $mg.l = -1; $mg.r = -1; $mg.t = -1; $mg.b = -1
        [void][DwmApi]::DwmExtendFrameIntoClientArea($hw, [ref]$mg)
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hw)
        if ($src) { $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent }
    } catch { Log ("dwm fail: " + $_.Exception.Message) }
}
$win.Show()
Set-PerPixelAlpha; $win.Activate() } })
        $script:Tray = $ni
        Log 'tray icon ready'
        try { $ni.ShowBalloonTip(4000, '照片桌宠 3D', '已启动，右键小猫或托盘图标打开菜单', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    } catch { Log ("tray fail: " + $_.Exception.Message) }
}

# ---------- 热更新（外观包 + 功能清单 + 页面） ----------
$script:PackDir = Join-Path $Runtime 'packs'
function Apply-RestCfg {
    try {
        $f = Join-Path $script:PackDir 'rest.json'
        if (-not (Test-Path $f)) { return }
        $raw = Get-Content $f -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return }
        $null = Run-Js ("window.pet.setRest(" + $raw.Trim() + ")")
        Log 'hot: rest cfg applied'
    } catch { Log ('rest cfg fail: ' + $_.Exception.Message) }
}

function Update-Models($man, $base, $stamp) {
    if (-not $man.models) { return }
    $dir = Join-Path $script:PackDir 'models'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($mm in $man.models) {
        try {
            $id = [string]$mm.id
            if (-not $id) { continue }
            $target = Join-Path $dir $id
            $pj = Join-Path $target 'pack.json'
            $need = $true
            if (Test-Path $pj) {
                try {
                    $lo = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$lo.ver -eq [string]$mm.ver) { $need = $false }
                } catch { }
            }
            if (-not $need) { continue }
            $tmp = Join-Path $env:TEMP ('petmodel-' + $id + '.zip')
            $url = $base + [string]$mm.file + $stamp
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 25 -UseBasicParsing
            if ((Get-Item $tmp).Length -lt 200) { Log ('model: tiny zip ' + $id); continue }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Expand-Archive -Path $tmp -DestinationPath $target -Force
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Log ('model: updated ' + $id + ' -> ' + [string]$mm.ver)
            if ([string]$script:S['model'] -eq $id) { Apply-Model }
        } catch { Log ('model ERR ' + [string]$mm.id + ': ' + $_.Exception.Message) }
    }
}

function Update-Host($m, $usedBase, $stamp) {
    try {
        if (-not $m.host) { return }
        $hv = [string]$m.host.ver
        if (-not $hv) { return }
        if (-not (Test-NewerVersion $hv $script:BuildVer)) { return }
        $hfile = [string]$m.host.file
        if (-not $hfile) { $hfile = 'host/pet3d.ps1' }
        $dst = Join-Path $Root 'runtime\pet3d.next.ps1'
        $ok = $false
        $bases2 = @($usedBase,
            'https://raw.githubusercontent.com/q137663972-alt/pet-live/main/',
            'https://cdn.jsdelivr.net/gh/q137663972-alt/pet-live@main/',
            'https://ghproxy.net/https://raw.githubusercontent.com/q137663972-alt/pet-live/main/')
        foreach ($b in $bases2) {
            if ($ok) { break }
            try {
                $t = (Invoke-WebRequest -Uri ($b + $hfile + $stamp) -TimeoutSec 20 -UseBasicParsing).Content
                if (($t.Length -gt 40000) -and $t.Contains('BuildVer') -and $t.Contains('function Update-Packs')) {
                    $hv2 = ([regex]::Match($t, "BuildVer = '([^']+)'")).Groups[1].Value
                    [IO.File]::WriteAllText($dst, $t, (New-Object System.Text.UTF8Encoding($true)))
                    $ok = $true
                    Log ('host: fetched ' + $hv2 + ' (manifest ' + $hv + ')')
                }
            } catch { }
        }
        if (-not $ok) { Log 'host: download failed'; return }
        $upd = Join-Path $Root 'runtime\hostup.ps1'
        $body = @'
param([string]$Root)
$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Milliseconds 400
for ($i = 0; $i -lt 80; $i++) {
    $alive = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*pet3d.ps1*' }
    if (-not $alive) { break }
    Start-Sleep -Milliseconds 300
}
Copy-Item (Join-Path $Root 'pet3d.ps1') (Join-Path $Root 'pet3d.old.ps1') -Force
Copy-Item (Join-Path $Root 'runtime\pet3d.next.ps1') (Join-Path $Root 'pet3d.ps1') -Force
Remove-Item (Join-Path $Root 'runtime\pet3d.next.ps1') -Force
$boot = Join-Path $Root 'boot.ps1'
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $boot + '"') -WorkingDirectory $Root
Start-Sleep -Seconds 9
$alive2 = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*pet3d.ps1*' }
if (-not $alive2) {
    Copy-Item (Join-Path $Root 'pet3d.old.ps1') (Join-Path $Root 'pet3d.ps1') -Force
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $boot + '"') -WorkingDirectory $Root
}
'@
        [IO.File]::WriteAllText($upd, $body, (New-Object System.Text.UTF8Encoding($true)))
        Log ('host: updating ' + $script:BuildVer + ' -> ' + $hv)
        Set-Bubble ('正在升级本体 ' + $hv)
        try { $script:NI.Visible = $false } catch { }
        $null = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $upd + '"'),('"' + $Root + '"') -WorkingDirectory $Root
        Start-Sleep -Milliseconds 250
        [Environment]::Exit(0)
    } catch { Log ('host ERR: ' + $_.Exception.Message) }
}

function Update-Packs {
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:PackDir 'looks') | Out-Null
        $bases = @(
            'https://raw.githubusercontent.com/q137663972-alt/pet-live/main/',
            'https://cdn.jsdelivr.net/gh/q137663972-alt/pet-live@main/',
            'https://ghproxy.net/https://raw.githubusercontent.com/q137663972-alt/pet-live/main/'
        )
        $m = $null; $usedBase = $null
        $stamp = '?t=' + [DateTime]::Now.Ticks
        # 多线路都拉一遍，取版本号最大的那份，避免 CDN 缓存导致“已是最新”误判
        $best = $null
        try {
            $api2 = 'https://api.github.com/repos/q137663972-alt/pet-live/contents/manifest.json?ref=main&t=' + [DateTime]::Now.Ticks
            $j2 = Invoke-RestMethod -Uri $api2 -TimeoutSec 10 -UseBasicParsing -Headers @{ 'User-Agent' = 'petd' }
            if ($j2 -and $j2.content) {
                $b64b = ($j2.content -replace '[^A-Za-z0-9+/=]', '')
                $best = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64b))
            }
        } catch { }
        foreach ($b in $bases) {
            try {
                $txt = (Invoke-WebRequest -Uri ($b + 'manifest.json' + $stamp) -TimeoutSec 8 -UseBasicParsing).Content
                if (-not $best) { $best = $txt; $usedBase = $b; continue }
                $tv = [string](($txt | ConvertFrom-Json).version)
                $bv = [string](($best | ConvertFrom-Json).version)
                if ($tv.CompareTo($bv) -gt 0) { $best = $txt; $usedBase = $b }
            } catch { }
        }
        if ($best) { $m = $best | ConvertFrom-Json }
        if (-not $usedBase) { $usedBase = $bases[0] }
        if (-not $m) { Log 'hot: manifest unreachable'; Set-Bubble '网络不通，稍后再试'; return }
        $verFile = Join-Path $script:PackDir 'version.txt'
        if ($m.rest) {
            $r = $null
            try {
                $api = 'https://api.github.com/repos/q137663972-alt/pet-live/contents/' + $m.rest + '?ref=main&t=' + [DateTime]::Now.Ticks
                $j = Invoke-RestMethod -Uri $api -TimeoutSec 10 -UseBasicParsing -Headers @{ 'User-Agent' = 'petd' }
                if ($j -and $j.content) {
                    $b64 = ($j.content -replace '[^A-Za-z0-9+/=]', '')
                    $r = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                }
            } catch { }
            if (-not $r) {
                try { $r = (Invoke-WebRequest -Uri ($usedBase + $m.rest + $stamp) -TimeoutSec 8 -UseBasicParsing).Content } catch { }
            }
            if ($r) {
                try {
                    [IO.File]::WriteAllText((Join-Path $script:PackDir 'rest.json'), $r, (New-Object System.Text.UTF8Encoding($false)))
                    Apply-RestCfg
                } catch { }
            }
        }
        Update-Models $m $usedBase $stamp
        Update-Host $m $usedBase $stamp
        $curVer = ''
        if (Test-Path $verFile) { try { $curVer = (Get-Content $verFile -Raw).Trim() } catch { } }
        if ($m.page -and (($curVer -ne [string]$m.version) -or (-not (Test-Path (Join-Path $Root 'cat3d\cat.hot.html'))))) {
            try {
                $pt = (Invoke-WebRequest -Uri ($usedBase + [string]$m.page + $stamp) -TimeoutSec 15 -UseBasicParsing).Content
                if (($pt.Length -gt 20000) -and $pt.Contains('HOTPAGE') -and $pt.Contains('window.pet')) {
                    [IO.File]::WriteAllText((Join-Path $Root 'cat3d\cat.hot.html'), $pt, (New-Object System.Text.UTF8Encoding($false)))
                    Log ('page: staged ' + $m.version)
                    if ($script:Ready -and ($script:PageFile -eq 'cat.hot.html')) { $null = $script:Core.ExecuteScriptAsync('location.reload()') }
                } else { Log 'page: rejected by validation' }
            } catch { Log ('page ERR: ' + $_.Exception.Message) }
        }
        if ((Test-Path $verFile) -and ((Get-Content $verFile -Raw).Trim() -eq [string]$m.version)) {
            Log ('hot: already ' + $m.version); Set-Bubble ('已是最新 ' + $m.version); Apply-PackLook; return
        }
        $count = 0
        foreach ($rel in $m.looks) {
            try {
                $txt = (Invoke-WebRequest -Uri ($usedBase + $rel) -TimeoutSec 8 -UseBasicParsing).Content
                $name = Split-Path $rel -Leaf
                [IO.File]::WriteAllText((Join-Path $script:PackDir ('looks\' + $name)), $txt, (New-Object System.Text.UTF8Encoding($false)))
                $count++
            } catch { }
        }
        if ($m.feats) {
            try {
                $f = (Invoke-WebRequest -Uri ($usedBase + $m.feats) -TimeoutSec 8 -UseBasicParsing).Content
                [IO.File]::WriteAllText((Join-Path $script:PackDir 'ops.json'), $f, (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
        if ($m.cats) {
            try {
                $cj = (Invoke-WebRequest -Uri ($usedBase + $m.cats + '?t=' + [DateTime]::Now.Ticks) -TimeoutSec 8 -UseBasicParsing).Content | ConvertFrom-Json
                $ids = @($script:CatsDoc.cats | ForEach-Object { $_.id })
                $added = 0
                foreach ($nc in $cj) {
                    if ($nc -and $nc.id -and ($ids -notcontains [string]$nc.id)) {
                        $script:CatsDoc.cats += $nc
                        $added++
                    }
                }
                if ($added -gt 0) { Save-Cats; Log ('hot: cats +' + $added) }
            } catch { }
        }
        Set-Content -Path $verFile -Value ([string]$m.version) -Encoding UTF8
        Log ('hot: updated ' + $m.version + ' looks=' + $count)
        Set-Bubble ('外观包已更新 ' + $m.version)
        Apply-PackLook
    } catch { Log ('hot fail: ' + $_.Exception.Message) }
}

function Apply-PackLook {
    try {
        $cat = Get-CatById ([string]$script:S['cat'])
        if (-not $cat) { return }
        $f = Join-Path $script:PackDir ('looks\' + $cat.id + '.json')
        if (-not (Test-Path $f)) { return }
        $look = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($look.kind -eq 'custom') {
            $obj = @{ kind = 'custom'; id = $look.id; fur = $look.fur; patch = $look.patch; accent = $look.accent
                      eye = $look.eye; eye2 = $look.eye2; pattern = $look.pattern; spots = @() }
            $j = ConvertTo-Json $obj -Depth 5 -Compress
            $null = Run-Js ("window.pet.setCoat(" + $j + ")")
            Log ('hot: applied look ' + $look.id)
        }
    } catch { Log ('hot look fail: ' + $_.Exception.Message) }
}
Start-Tray
Start-GlobalInput
$script:HotTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HotTimer.Interval = [TimeSpan]::FromMinutes(30)
$script:HotTimer.add_Tick({ Update-Packs })
$script:HotBoot = New-Object System.Windows.Threading.DispatcherTimer
$script:HotBoot.Interval = [TimeSpan]::FromSeconds(6)
$script:HotBoot.add_Tick({ $script:HotBoot.Stop(); Update-Packs; $script:HotTimer.Start() })
$script:HotBoot.Start()
$script:HotTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HotTimer.Interval = [TimeSpan]::FromMinutes(30)
$script:HotTimer.add_Tick({ Update-Packs })
$script:HotTimer.Start()


[System.Windows.Threading.Dispatcher]::Run()

Log 'bye'

