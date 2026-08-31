using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Minimal ConPTY host: runs a command attached to a pseudoconsole, captures
// its output, and injects a simulated burst of terminal query replies (as a
// real terminal such as Windows Terminal would send) into the input pipe.
public static class ConPtyHost
{
    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
        public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, IntPtr lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll")]
    static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToRead, out int lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToWrite, out int lpNumberOfBytesWritten, IntPtr lpOverlapped);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x20016;

    // ConPTY requests win32-input-mode ([?9001h) from the hosting terminal;
    // Windows Terminal then encodes every input char as CSI Vk;Sc;Uc;Kd;Cs;Rc _
    // and conhost reconstructs KEY_EVENTs from it. Raw VT text that merely
    // *looks* like query replies gets eaten by conhost's input parser, so a
    // faithful WT simulation must use this encoding.
    public static string Win32InputEncode(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s)
            sb.Append("\x1b[0;0;" + (int)c + ";1;0;1_");
        return sb.ToString();
    }

    // Simulated Windows-Terminal-style reply burst to notcurses' initial queries.
    static byte[] BuildReplyBurst()
    {
        var sb = new StringBuilder();
        sb.Append("\x1b[1;1R"); // CPR reply to the leading u7 (DSRCPR) query
        for (int i = 0; i < 256; i++)
            sb.Append("\x1b]4;" + i + ";rgb:afaf/afaf/8787\x1b\\");
        sb.Append("\x1b]10;rgb:cccc/cccc/cccc\x1b\\");
        sb.Append("\x1b]11;rgb:0c0c/0c0c/0c0c\x1b\\");
        sb.Append("\x1b[?2026;2$y");
        sb.Append("\x1b[?1016;0$y");
        sb.Append("\x1b[4;600;1200t");
        sb.Append("\x1b[8;30;120t");
        sb.Append("\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c");
        return Encoding.ASCII.GetBytes(Win32InputEncode(sb.ToString()));
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

    // Run `commandLine` under a ConPTY; after `burstDelayMs`, inject the reply
    // burst; after `resizeDelayMs` (if >= 0) resize the ConPTY to rw x rh;
    // after `keyDelayMs` (if >= 0), inject `key`. Output is written to
    // `outLog`. Returns the process exit code.
    public static int Run(string commandLine, string workDir, string outLog, int burstDelayMs, int keyDelayMs, string key, int timeoutMs)
    {
        return Run(commandLine, workDir, outLog, burstDelayMs, keyDelayMs, key, timeoutMs, -1, 0, 0);
    }

    public static int Run(string commandLine, string workDir, string outLog, int burstDelayMs, int keyDelayMs, string key, int timeoutMs, int resizeDelayMs, short rw, short rh)
    {
        IntPtr inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0)) throw new Exception("CreatePipe in");
        if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new Exception("CreatePipe out");

        COORD size; size.X = 120; size.Y = 30;
        IntPtr hpc;
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out hpc);
        if (hr != 0) throw new Exception("CreatePseudoConsole hr=" + hr);

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize)) throw new Exception("InitializeProcThreadAttributeList");
        if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("UpdateProcThreadAttribute");

        var six = new STARTUPINFOEX();
        six.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        six.lpAttributeList = attrList;
        // Sever the inherited std handles: the pseudoconsole client must use
        // its console, not the host's stdio (STARTF_USESTDHANDLES with NULLs).
        six.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES

        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
            EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, workDir, ref six, out pi))
            throw new Exception("CreateProcess err=" + Marshal.GetLastWin32Error());

        // output pump
        var pump = new Thread(() =>
        {
            using (var fs = new FileStream(outLog, FileMode.Create, FileAccess.Write))
            {
                var buf = new byte[4096];
                int n;
                while (ReadFile(outRead, buf, buf.Length, out n, IntPtr.Zero) && n > 0)
                    fs.Write(buf, 0, n);
            }
        });
        pump.IsBackground = true;
        pump.Start();

        if (burstDelayMs >= 0)
        {
            Thread.Sleep(burstDelayMs);
            var burst = BuildReplyBurst();
            int w;
            WriteFile(inWrite, burst, burst.Length, out w, IntPtr.Zero);
        }
        if (resizeDelayMs >= 0)
        {
            Thread.Sleep(resizeDelayMs);
            COORD ns; ns.X = rw; ns.Y = rh;
            ResizePseudoConsole(hpc, ns);
        }
        if (keyDelayMs >= 0)
        {
            Thread.Sleep(keyDelayMs);
            var kb = Encoding.ASCII.GetBytes(Win32InputEncode(key));
            int w;
            WriteFile(inWrite, kb, kb.Length, out w, IntPtr.Zero);
        }

        uint waitRes = WaitForSingleObject(pi.hProcess, (uint)timeoutMs);
        uint code = 9999;
        if (waitRes == 0) GetExitCodeProcess(pi.hProcess, out code);

        ClosePseudoConsole(hpc);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        CloseHandle(inRead); CloseHandle(inWrite); CloseHandle(outWrite);
        Thread.Sleep(200); // let the pump drain
        CloseHandle(outRead);
        Marshal.FreeHGlobal(attrList);
        return waitRes == 0 ? (int)code : -258;
    }
}
