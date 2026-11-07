import Foundation

/// The same few facts on a native Windows Host (ADR 0034), as one bounded exec of
/// PowerShell, which prints the lines the POSIX script prints.
///
/// Windows has no `/proc`. The tree comes from CIM, a process's start is its
/// creation FILETIME as decimal digits, the value the Heeler extension's label
/// reads the same way (`StartTime.ToFileTimeUtc()`), and its variables
/// come from the environment block in its own memory. As on POSIX the script filters
/// on the Host: no other variable's name or value leaves it. Open files and argv are
/// never read here, so they answer unavailable.
///
/// `HOME` reads from `USERPROFILE`, the home these programs use on Windows. Only one
/// process's own memory is read, and a process another account owns reads as
/// unavailable. Nothing here has run on a Windows machine (herdr compatibility).
extension HostProcessReader {
    /// What `cmd.exe` takes, and OpenSSH starts an exec through the account's shell.
    static let windowsCommandLimit = 8_191

    static func windowsCommand(_ request: Request, nonce: String) throws -> String {
        for pid in request.pids where !isProcessID(pid) { throw Refusal.pid(pid) }
        guard request.pids.count <= processCap else { throw Refusal.tooManyProcesses(request.pids.count) }
        if let root = request.descendantsOf, !request.pids.contains(root) { throw Refusal.descendantRoot(root) }
        // The script prints a name in upper case, whatever case the block holds.
        for name in request.valuesOf + request.namesOf + request.namesWithPrefix
        where !isVariableName(name) || name != name.uppercased() {
            throw Refusal.variableName(name)
        }

        func list(_ names: [String]) -> String {
            "@(\(names.map { "'\($0)'" }.joined(separator: ",")))"
        }
        let wanted = request.valuesOf.map { $0 == windowsHomeAlias ? windowsHomeVariable : $0 }
        let script = [
            HerdrCoreLocator.windowsPrelude,
            "$ErrorActionPreference='Stop'",
            // The block's offsets below hold for a 64-bit reader only.
            "if([IntPtr]::Size -ne 8){exit 1}",
            windowsHelpers,
            "$ids=@(\(request.pids.joined(separator: ",")))",
            "$root=\(request.descendantsOf ?? "0")",
            "$want=\(list(wanted))",
            "$names=\(list(request.namesOf))",
            "$pre='\(prefixPattern(request.namesWithPrefix))'",
            windowsBody,
            // The command line's budget goes further without a walk nobody asked for.
            request.descendantsOf == nil ? "" : windowsWalk,
            "say ''",
            "say '\(endMarker(nonce))'",
            "exit 0",
        ]
        .joined(separator: "\n")
        .replacingOccurrences(of: windowsBeginPlaceholder, with: beginMarker(nonce))
        let command = PowerShellCommand.encoded(script)
        guard command.utf8.count <= windowsCommandLimit else {
            throw Refusal.tooManyProcesses(request.pids.count)
        }
        return command
    }

    /// As ``parse(stdout:nonce:request:)``, with each fact in the form the binder's
    /// rules already read: an image's name without `.exe` or case, and an absolute
    /// path as the form SFTP opens and `RemoteFilePath` takes.
    static func parseWindows(stdout: Data, nonce: String, request: Request) throws -> [String: Facts] {
        try parse(stdout: stdout, nonce: nonce, request: request).mapValues { facts in
            var facts = facts
            facts.name = facts.name.map(windowsProgramName)
            facts.variables = facts.variables.mapValues { variable in
                guard case .value(let value) = variable else { return variable }
                return .value(RemoteFilePath.windowsForSFTP(value))
            }
            return facts
        }
    }

    /// A whole name in upper case that starts with one of these, empty for none.
    /// Each is a checked variable name, so none of them is regex syntax, and a name
    /// that could not stand as one word on a line is not printed at all.
    private static func prefixPattern(_ prefixes: [String]) -> String {
        prefixes.isEmpty ? "" : "^(?:\(prefixes.joined(separator: "|")))[A-Z0-9_]*$"
    }

    private static let windowsHomeAlias = "HOME"
    private static let windowsHomeVariable = "USERPROFILE"
    private static let windowsBeginPlaceholder = "__HEELER_PROC_BEGIN_MARKER__"

    private static func windowsProgramName(_ image: String) -> String {
        let name = image.lowercased()
        return name.hasSuffix(".exe") ? String(name.dropLast(".exe".count)) : name
    }

    /// C# 5, which Windows PowerShell 5.1 compiles. `Env` is the raw block, read after
    /// the size and pointer in `RTL_USER_PROCESS_PARAMETERS`, for the caller to filter.
    /// A failed read leaves zeros, which its size check turns away, and the process
    /// ends at once, so its handles need no closing.
    private static let windowsHelpers = """
        Add-Type -TypeDefinition @'
        using System;using System.Runtime.InteropServices;
        public static class HeelerProc{
        [DllImport("kernel32")]static extern IntPtr OpenProcess(int a,bool i,int p);
        [DllImport("kernel32")]static extern bool ReadProcessMemory(IntPtr h,IntPtr a,byte[] b,IntPtr n,out IntPtr r);
        [DllImport("ntdll")]static extern int NtQueryInformationProcess(IntPtr h,int c,IntPtr[] b,int n,out int r);
        static long Q(IntPtr h,long a){byte[] b=new byte[8];IntPtr r;ReadProcessMemory(h,(IntPtr)a,b,(IntPtr)8,out r);return BitConverter.ToInt64(b,0);}
        public static string Env(int p){IntPtr h=OpenProcess(0x410,false,p),g;IntPtr[] i=new IntPtr[6];int r;if(h==IntPtr.Zero||NtQueryInformationProcess(h,0,i,48,out r)!=0)return null;long q=Q(h,i[1].ToInt64()+0x20),n=Q(h,q+0x3F0);if(n<=0||n>1048576)return null;byte[] b=new byte[n];return ReadProcessMemory(h,(IntPtr)Q(h,q+0x80),b,(IntPtr)n,out g)?System.Text.Encoding.Unicode.GetString(b):null;}
        }
        '@
        """

    /// A process's start is 0 when it cannot be read, so it prints `-`. Open files and
    /// argv always read as unavailable, and the parser takes an answer nobody asked for.
    private static let windowsBody = """
        function hexOf($v){-join([Text.Encoding]::UTF8.GetBytes($v)|%{$_.ToString('x2')})}
        function startOf($p){try{[Diagnostics.Process]::GetProcessById($p).StartTime.ToFileTimeUtc()}catch{0}}
        function readOne($p){
        $t=startOf $p;say "S $p $(if($t){$t}else{'-'})"
        if($want.Count+$names.Count+$pre.Length){
        $b=[HeelerProc]::Env($p)
        if($b){
        foreach($e in $b.Split([char]0)){
        if(!$e){break}
        $at=$e.IndexOf('=',1);if($at -lt 1){continue}
        $n=$e.Substring(0,$at);$v=$e.Substring($at+1)
        if($want -contains $n){say "V $p $($n.ToUpper()-replace'^\(windowsHomeVariable)$','\(windowsHomeAlias)') $(if($v){hexOf $v}else{'-'})"}
        if($v -and ($names -contains $n -or ($pre -and $n.ToUpper()-cmatch$pre))){say "N $p $($n.ToUpper())"}
        }
        say "E $p ok"
        }else{say "E $p -"}
        }
        say "O $p -";say "B $p -"
        }
        say ''
        say '\(windowsBeginPlaceholder)'
        foreach($p in $ids){readOne $p}
        """

    /// A child older than its parent is under a pid that was reused, so it is not one.
    /// Past the cap only the root's own line prints, as on POSIX.
    private static let windowsWalk = """
        function imageOf($c){if($c.Name -cmatch '^[A-Za-z0-9._-]+$'){$c.Name}else{'-'}}
        if($root){
        $all=@{};$kids=@{}
        foreach($c in gcim Win32_Process -Property ProcessId,ParentProcessId,Name){
        $me=[int]$c.ProcessId;$all[$me]=$c;$kids[[int]$c.ParentProcessId]+=,$me
        }
        $walk=@($root);$met=@{$root=1};$h=0
        while($h -lt $walk.Count){
        $o=$walk[$h];$h++
        foreach($y in $kids[$o]){
        if($met[$y] -or (startOf $y) -lt (startOf $o)){continue}
        $met[$y]=1;$walk+=$y
        }
        }
        if($all[$root]){say "T $root $($all[$root].ParentProcessId) $(imageOf $all[$root])"}
        if($walk.Count-1 -gt \(processCap)){say "W $root -"}else{
        $tail=$walk|select -Skip 1
        foreach($y in $tail){say "T $y $($all[$y].ParentProcessId) $(imageOf $all[$y])"}
        say "W $root ok"
        foreach($y in $tail){readOne $y}
        }
        }
        """
}
