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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startup,
            out ProcessInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

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
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法创建独立 MATLAB COM 持有进程");
            try { return checked((int)information.processId); }
            finally
            {
                CloseHandle(information.thread);
                CloseHandle(information.process);
            }
        }
    }
}
