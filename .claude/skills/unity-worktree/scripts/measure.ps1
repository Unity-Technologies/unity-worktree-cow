<#
    Private disk per tree on Windows/ReFS, by physical-cluster overlap.

    usage: measure.ps1 [-Target NAME[;NAME...]] [-By N] [-Json] [NAME=]DIR...

    Every DIR takes part; -Target picks which ones are reported (default: all),
    by NAME or by path. -By N groups private bytes by the first N path parts.
    A cluster is private to a tree when no other tree maps it. Trees nested in
    another (the golden under .git) are skipped when walking the outer one.

    Why not refcounts: summing Ref == 1 clusters from
    FSCTL_GET_RETRIEVAL_POINTERS_AND_REFCOUNT (fsutil file
    queryExtentsAndRefCounts) is not deterministic in bulk after heavy writes
    on the volume. An idle golden read anywhere from 197 to 1,642 MiB private
    across six runs, with 10-25k files flipping Ref 1 <-> 2 by one cluster.
    Physical LCNs from FSCTL_GET_RETRIEVAL_POINTERS do not move.

    Files with data but no extents are stored inline in ReFS metadata; each
    counts as one private cluster. Free space and du are not valid measures.

    Called by `uwt measure`; usable on its own.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Target,
    [int]$By = 2,
    [switch]$Json,
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Tree
)
$ErrorActionPreference = 'Stop'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class UwtLcn {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, ref long inBuf, int inLen, byte[] outBuf, int outLen, out int ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool GetDiskFreeSpaceW(string root, out uint spc, out uint bps, out uint free, out uint total);

    const uint FSCTL_GET_RETRIEVAL_POINTERS = 0x00090073;
    const int ERROR_MORE_DATA = 234, ERROR_HANDLE_EOF = 38;

    public static long ClusterBytes(string path) {
        uint spc, bps, f, t;
        if (!GetDiskFreeSpaceW(Path.GetPathRoot(Path.GetFullPath(path)), out spc, out bps, out f, out t))
            throw new IOException("GetDiskFreeSpace failed for " + path);
        return (long)spc * bps;
    }

    // Appends [lcn, lcn+len) runs to runs (pairs). Returns false if the file
    // could not be opened. Holes (Lcn -1) are skipped.
    static bool Extents(string path, List<long> runs) {
        // FILE_READ_ATTRIBUTES is enough, and opens files an editor holds exclusively.
        using (var h = CreateFileW(@"\\?\" + path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            var buf = new byte[64 * 1024];
            long vcn = 0;
            while (true) {
                int ret;
                bool ok = DeviceIoControl(h, FSCTL_GET_RETRIEVAL_POINTERS, ref vcn, 8, buf, buf.Length, out ret, IntPtr.Zero);
                int err = ok ? 0 : Marshal.GetLastWin32Error();
                // EOF: an empty or resident file, which has no extents.
                if (!ok && err != ERROR_MORE_DATA) return err == ERROR_HANDLE_EOF;
                int n = BitConverter.ToInt32(buf, 0);
                long prev = BitConverter.ToInt64(buf, 8);
                for (int i = 0; i < n; i++) {
                    long next = BitConverter.ToInt64(buf, 16 + i * 16);
                    long lcn = BitConverter.ToInt64(buf, 24 + i * 16);
                    if (lcn >= 0) { runs.Add(lcn); runs.Add(lcn + (next - prev)); }
                    prev = next;
                }
                if (ok || n == 0) return true;
                vcn = prev;
            }
        }
    }

    public class TreeResult {
        public string Root;
        public long Files, Logical, Inline, Unreadable, Allocated, Private;
        public Dictionary<string, long[]> Groups = new Dictionary<string, long[]>(); // files, logical, private clusters
        internal long[] Runs;              // merged [lo, hi) pairs
    }

    static string GroupKey(string rel, int by) {
        var parts = rel.Split('\\');
        if (parts.Length > by) return string.Join("\\", parts, 0, by);
        return parts.Length > 1 ? string.Join("\\", parts, 0, parts.Length - 1) : ".";
    }

    static void Walk(TreeResult t, string dir, HashSet<string> skip, int by, List<long> fileRuns, List<string> fileGroup) {
        var stack = new Stack<string>();
        stack.Push(dir);
        while (stack.Count > 0) {
            var d = stack.Pop();
            DirectoryInfo di = new DirectoryInfo(d);
            IEnumerable<FileSystemInfo> items;
            try { items = di.EnumerateFileSystemInfos(); } catch { continue; }
            foreach (var fsi in items) {
                if ((fsi.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                if ((fsi.Attributes & FileAttributes.Directory) != 0) {
                    if (!skip.Contains(fsi.FullName.TrimEnd('\\').ToLowerInvariant())) stack.Push(fsi.FullName);
                    continue;
                }
                long len = ((FileInfo)fsi).Length;
                string key = GroupKey(fsi.FullName.Substring(t.Root.Length).TrimStart('\\'), by);
                long[] g;
                if (!t.Groups.TryGetValue(key, out g)) { g = new long[3]; t.Groups[key] = g; }
                t.Files++; t.Logical += len; g[0]++; g[1] += len;
                int before = fileRuns.Count;
                if (!Extents(fsi.FullName, fileRuns)) { t.Unreadable++; continue; }
                if (fileRuns.Count == before && len > 0) {
                    t.Inline++; g[2]++;   // resident: one cluster, owned by nobody else
                }
                for (int i = before; i < fileRuns.Count; i += 2) fileGroup.Add(key);
            }
        }
    }

    static long[] Merge(List<long> runs) {
        int n = runs.Count / 2;
        var idx = new int[n];
        var lo = new long[n];
        for (int i = 0; i < n; i++) { idx[i] = i; lo[i] = runs[2 * i]; }
        Array.Sort(lo, idx);
        var outp = new List<long>();
        foreach (int i in idx) {
            long a = runs[2 * i], b = runs[2 * i + 1];
            int m = outp.Count;
            if (m > 0 && a <= outp[m - 1]) { if (b > outp[m - 1]) outp[m - 1] = b; }
            else { outp.Add(a); outp.Add(b); }
        }
        return outp.ToArray();
    }

    // Clusters of [a, b) not covered by merged, sorted intervals `cover`.
    static long Uncovered(long[] cover, long a, long b) {
        int lo = 0, hi = cover.Length / 2;
        while (lo < hi) { int mid = (lo + hi) / 2; if (cover[2 * mid + 1] <= a) lo = mid + 1; else hi = mid; }
        long covered = 0;
        for (int i = lo; i < cover.Length / 2 && cover[2 * i] < b; i++)
            covered += Math.Min(b, cover[2 * i + 1]) - Math.Max(a, cover[2 * i]);
        return (b - a) - covered;
    }

    public static TreeResult[] Measure(string[] roots, bool[] report, int by) {
        int n = roots.Length;
        var skip = new HashSet<string>();
        foreach (var r in roots) skip.Add(r.TrimEnd('\\').ToLowerInvariant());
        var res = new TreeResult[n];
        var raw = new List<long>[n];
        var grp = new List<string>[n];
        for (int k = 0; k < n; k++) {
            res[k] = new TreeResult { Root = roots[k].TrimEnd('\\') };
            raw[k] = new List<long>(); grp[k] = new List<string>();
            var own = new HashSet<string>(skip); own.Remove(res[k].Root.ToLowerInvariant());
            Walk(res[k], res[k].Root, own, by, raw[k], grp[k]);
            res[k].Runs = Merge(raw[k]);
            for (int i = 0; i < res[k].Runs.Length; i += 2) res[k].Allocated += res[k].Runs[i + 1] - res[k].Runs[i];
            res[k].Allocated += res[k].Inline;
        }
        for (int k = 0; k < n; k++) {
            if (!report[k]) continue;
            var others = new List<long>();
            for (int j = 0; j < n; j++) if (j != k) others.AddRange(res[j].Runs);
            var cover = Merge(others);
            long priv = res[k].Inline;
            for (int i = 0; i < res[k].Runs.Length; i += 2) priv += Uncovered(cover, res[k].Runs[i], res[k].Runs[i + 1]);
            res[k].Private = priv;
            // Per group: a group's raw runs against everyone else. Runs shared only
            // within this tree count toward each group that holds them.
            for (int i = 0; i < raw[k].Count; i += 2)
                res[k].Groups[grp[k][i / 2]][2] += Uncovered(cover, raw[k][i], raw[k][i + 1]);
        }
        return res;
    }
}
'@

$names = @(); $roots = @()
foreach ($t in $Tree) {
    # NAME=DIR; a bare drive path (E:\x) has no name.
    if ($t -match '^([^=:\\/]+)=(.+)$') { $n = $Matches[1]; $p = $Matches[2] } else { $n = $null; $p = $t }
    $r = (Resolve-Path -LiteralPath $p).ProviderPath.TrimEnd('\')
    $roots += $r; $names += $(if ($n) { $n } else { $r })
}
$want = @(if ($Target) { $Target -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/').ToLowerInvariant() } })
$report = [bool[]]@(for ($k = 0; $k -lt $roots.Count; $k++) {
    $want.Count -eq 0 -or $want -contains $names[$k].ToLowerInvariant() -or $want -contains $roots[$k].ToLowerInvariant()
})
$cl = [UwtLcn]::ClusterBytes($roots[0])
$t0 = Get-Date
$res = [UwtLcn]::Measure([string[]]$roots, $report, $By)
$secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

$out = [ordered]@{ method = 'lcn-overlap'; cluster_bytes = $cl; seconds = $secs; trees = @() }
for ($k = 0; $k -lt $res.Count; $k++) {
    $r = $res[$k]
    $row = [ordered]@{
        name = $names[$k]; path = $r.Root; reported = $report[$k]
        files = $r.Files; logical = $r.Logical; inline_files = $r.Inline; unreadable = $r.Unreadable
        allocated = $r.Allocated * $cl
    }
    if ($report[$k]) {
        $row.private = $r.Private * $cl
        $row.shared = ($r.Allocated - $r.Private) * $cl
        $row.groups = [ordered]@{}
        foreach ($g in ($r.Groups.GetEnumerator() | Sort-Object { -$_.Value[2] } | Select-Object -First 25)) {
            if ($g.Value[2] -gt 0) { $row.groups[$g.Key] = [ordered]@{ files = $g.Value[0]; logical = $g.Value[1]; private = $g.Value[2] * $cl } }
        }
    }
    $out.trees += $row
}
if ($Json) { $out | ConvertTo-Json -Depth 6 -Compress; exit 0 }

$MB = 1048576.0
'{0,-12} {1,9} {2,12} {3,12} {4,12} {5,8}' -f 'tree', 'files', 'logical', 'allocated', 'private', 'shared%'
foreach ($t in $out.trees) {
    if (-not $t.reported) { continue }
    $pct = if ($t.allocated) { 100.0 * $t.shared / $t.allocated } else { 0 }
    '{0,-12} {1,9:N0} {2,8:N0} MiB {3,8:N0} MiB {4,8:N0} MiB {5,7:N1}%' -f $t.name, $t.files, ($t.logical / $MB), ($t.allocated / $MB), ($t.private / $MB), $pct
}
foreach ($t in $out.trees) {
    if (-not $t.reported -or $t.groups.Count -eq 0) { continue }
    ''; "largest private in $($t.name):"
    foreach ($k in @($t.groups.Keys)[0..([Math]::Min(9, $t.groups.Count - 1))]) {
        '  {0,10:N1} MiB  {1,8:N0} files  {2}' -f ($t.groups[$k].private / $MB), $t.groups[$k].files, $k
    }
}
"($($res.Count) trees, $secs s, $cl-byte clusters; inline files count one cluster each)"
