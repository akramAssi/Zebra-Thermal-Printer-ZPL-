using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;

static class Program {
  const string Marker = "ZEBRAZIP1";

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern int MessageBox(IntPtr owner, string text, string caption, uint type);

  static int Main() {
    string tempZip = Path.Combine(Path.GetTempPath(), "zebra-printer-setup.zip");
    try {
      string self = Process.GetCurrentProcess().MainModule.FileName;
      byte[] marker = Encoding.ASCII.GetBytes(Marker);
      int at = LastIndexOf(self, marker);
      if (at < 0) {
        Tell("This setup file is incomplete.");
        return 1;
      }

      using (var input = new FileStream(self, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
        input.Position = at + marker.Length;
        using (var output = File.Create(tempZip)) {
          input.CopyTo(output);
        }
      }

      string dest = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ZebraPrinter");
      foreach (var process in Process.GetProcessesByName("zebra_printer_agent")) {
        try {
          string path = process.MainModule.FileName;
          if (path != null && path.StartsWith(dest, StringComparison.OrdinalIgnoreCase)) {
            process.Kill();
            process.WaitForExit(4000);
          }
        } catch {
        }
      }

      if (Directory.Exists(dest)) Directory.Delete(dest, true);
      ZipFile.ExtractToDirectory(tempZip, dest);

      string exe = Path.Combine(dest, "zebra_printer_agent.exe");
      Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Zebra Printer.lnk"), exe, dest);
      Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Zebra Printer.lnk"), exe, dest);

      bool alreadyOpen = Process.GetProcessesByName("zebra_printer_agent").Length > 0;
      if (!alreadyOpen) {
        Process.Start(new ProcessStartInfo {
          FileName = exe,
          WorkingDirectory = dest,
          UseShellExecute = true,
        });
        Tell("Zebra Printer is installed and open.");
      } else {
        Tell("Zebra Printer is installed. Close the copy that is already open, then use the desktop shortcut.");
      }
      return 0;
    } catch (Exception error) {
      Tell(error.Message);
      return 1;
    } finally {
      try {
        if (File.Exists(tempZip)) File.Delete(tempZip);
      } catch {
      }
    }
  }

  static void Shortcut(string linkPath, string exe, string work) {
    Type shellType = Type.GetTypeFromProgID("WScript.Shell");
    dynamic shell = Activator.CreateInstance(shellType);
    dynamic link = shell.CreateShortcut(linkPath);
    link.TargetPath = exe;
    link.WorkingDirectory = work;
    link.Description = "Zebra Printer";
    link.Save();
  }

  static int LastIndexOf(string path, byte[] needle) {
    byte[] file = File.ReadAllBytes(path);
    for (int i = file.Length - needle.Length; i >= 0; i--) {
      bool match = true;
      for (int j = 0; j < needle.Length; j++) {
        if (file[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  static void Tell(string text) {
    MessageBox(IntPtr.Zero, text, "Zebra Printer", 0);
  }
}
