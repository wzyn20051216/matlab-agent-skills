using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace MasDesktop
{
    /// <summary>创建脱离调用者 Job 的隐藏持有进程，不继承管道或标准句柄。</summary>
    public static class NativeProcess
    {
        public const uint CreationFlags = 0x01000000 | 0x08000000; // BREAKAWAY_FROM_JOB | NO_WINDOW
        private const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
        private const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public uint cb;
            public string reserved, desktop, title;
            public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
            public ushort showWindow, reservedSize;
            public IntPtr reservedBytes, stdInput, stdOutput, stdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr process, thread;
            public uint processId, threadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long perProcessUserTimeLimit, perJobUserTimeLimit;
            public uint limitFlags;
            public UIntPtr minimumWorkingSetSize, maximumWorkingSetSize;
            public uint activeProcessLimit;
            public UIntPtr affinity;
            public uint priorityClass, schedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong readOperationCount, writeOperationCount, otherOperationCount;
            public ulong readTransferCount, writeTransferCount, otherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation basicLimitInformation;
            public IoCounters ioInfo;
            public UIntPtr processMemoryLimit, jobMemoryLimit;
            public UIntPtr peakProcessMemoryUsed, peakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startup,
            out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool inJob);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(IntPtr job, int infoClass,
            IntPtr info, int length, out int returnLength);

        /// <summary>只读查询：当前进程是否位于 Job、该 Job 是否允许 breakaway。不创建任何进程。</summary>
        public static string DescribeBreakawayState()
        {
            bool inJob;
            if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inJob))
                return "IN_JOB=UNKNOWN;QUERY_ERROR=" + Marshal.GetLastWin32Error();
            if (!inJob) return "IN_JOB=0;BREAKAWAY_REQUIRED=0";
            int size = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                int written;
                if (!QueryInformationJobObject(IntPtr.Zero, JobObjectExtendedLimitInformation, buffer, size, out written))
                    return "IN_JOB=1;QUERY_ERROR=" + Marshal.GetLastWin32Error();
                var extended = (ExtendedLimitInformation)Marshal.PtrToStructure(buffer, typeof(ExtendedLimitInformation));
                uint flags = extended.basicLimitInformation.limitFlags;
                bool breakawayOk = (flags & JOB_OBJECT_LIMIT_BREAKAWAY_OK) != 0;
                bool silentOk = (flags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) != 0;
                return string.Format("IN_JOB=1;LIMIT_FLAGS=0x{0:X4};BREAKAWAY_OK={1};SILENT_BREAKAWAY_OK={2}",
                    flags, breakawayOk ? 1 : 0, silentOk ? 1 : 0);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        /// <summary>CREATE_BREAKAWAY_FROM_JOB 能否成功；不在 Job 中时总是允许。</summary>
        public static bool CanBreakaway()
        {
            string state = DescribeBreakawayState();
            return state.StartsWith("IN_JOB=0", StringComparison.Ordinal) ||
                   state.Contains("BREAKAWAY_OK=1") ||
                   state.Contains("SILENT_BREAKAWAY_OK=1");
        }

        /// <summary>只关闭自己获得的内核句柄；不等待、不终止任何子进程。</summary>
        public static int StartDetached(string application, string arguments, string directory)
        {
            var startup = new StartupInfo();
            startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.flags = 1; // STARTF_USESHOWWINDOW，未设置 STARTF_USESTDHANDLES
            startup.showWindow = 0;
            ProcessInformation information;
            var commandLine = new StringBuilder("\"" + application + "\" " + arguments);
            if (!CreateProcessW(application, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                CreationFlags, IntPtr.Zero, directory, ref startup, out information))
            {
                int code = Marshal.GetLastWin32Error();
                // 自定义消息会覆盖系统消息，因此显式带上 Win32 码与其系统文本，便于归因。
                throw new Win32Exception(code, string.Format(
                    "无法创建独立 MATLAB COM 持有进程（Win32 {0}: {1}；{2}）",
                    code, new Win32Exception(code).Message, DescribeBreakawayState()));
            }
            try { return checked((int)information.processId); }
            finally
            {
                CloseHandle(information.thread);
                CloseHandle(information.process);
            }
        }
    }
}
