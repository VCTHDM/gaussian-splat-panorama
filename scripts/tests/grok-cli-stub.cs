using System;
using System.IO;
using System.Text;

namespace GrokStub
{
    internal static class Program
    {
        static int Main(string[] args)
        {
            var logdir = Environment.GetEnvironmentVariable("GROK_STUB_LOGDIR") ?? ".";
            Directory.CreateDirectory(logdir);
            var utf8 = new UTF8Encoding(false);
            File.WriteAllText(Path.Combine(logdir, "stub-commandline.txt"), Environment.CommandLine, utf8);
            File.WriteAllText(Path.Combine(logdir, "stub-argv.txt"), string.Join("\n", args), utf8);

            var mode = Environment.GetEnvironmentVariable("GROK_STUB_MODE") ?? "end_turn";
            var stderrExtra = Environment.GetEnvironmentVariable("GROK_STUB_STDERR") ?? "";
            const string session = "stub-session-0001";
            int exit = 0;
            string stdout = "";

            switch (mode)
            {
                case "end_turn":
                    stdout = Json("hello", session, "end_turn");
                    break;
                case "nonzero":
                    stdout = Json("fail body", session, "end_turn");
                    exit = 7;
                    break;
                case "empty":
                    stdout = "";
                    exit = 0;
                    break;
                case "max_turns":
                    stdout = Json("partial", session, "max_turns");
                    break;
                case "unknown_stop":
                    stdout = Json("hmm", session, "something_new");
                    break;
                default:
                    stdout = Json("hello", session, mode);
                    break;
            }

            if (!string.IsNullOrEmpty(stderrExtra))
            {
                Console.Error.Write(stderrExtra);
                Console.Error.Flush();
            }
            Console.Out.Write(stdout);
            Console.Out.Flush();
            return exit;
        }

        static string Json(string text, string sid, string stop)
        {
            string t = text.Replace("\\", "\\\\").Replace("\"", "\\\"");
            return "{\"text\":\"" + t + "\",\"sessionId\":\"" + sid + "\",\"stopReason\":\"" + stop +
                   "\",\"usage\":{\"input\":1,\"output\":1},\"modelUsage\":{\"grok-4.6-build\":{\"input\":1}}}";
        }
    }
}
