// Offline protocol fixture. It never opens a socket or executes the uploaded shell.
using System;
using System.Text;
using System.Text.RegularExpressions;

public static class SshFixture
{
    public static int Main(string[] args)
    {
        string arguments = string.Join(" ", args);
        if (!arguments.Contains("StrictHostKeyChecking=ask") ||
            !arguments.Contains("root@203.0.113.10") || !arguments.Contains("sh -s")) return 31;
        string payload = Console.In.ReadToEnd();
        Match settings = Regex.Match(payload,
            "base64 -d >\"\\$taskdir/server.env\" <<'__WG_SETTINGS__'\\n([A-Za-z0-9+/=]+)\\n__WG_SETTINGS__");
        if (!settings.Success || !payload.Contains("--export-stdout")) return 32;
        string config = Encoding.UTF8.GetString(Convert.FromBase64String(settings.Groups[1].Value));
        if (!config.Contains("ENDPOINT=example.com\n") || !config.Contains("WG_PORT=51821\n")) return 33;
        byte[] first = new byte[32], second = new byte[32];
        for (int i = 0; i < 32; i++) { first[i] = (byte)(i + 1); second[i] = (byte)(i + 33); }
        string[] names = { "wg-router.conf", "wg-test.conf" };
        string[] keys = { Convert.ToBase64String(first), Convert.ToBase64String(second) };
        Console.WriteLine("OFFLINE SSH FIXTURE");
        for (int i = 0; i < 2; i++)
        {
            string content = "[Interface]\nPrivateKey = " + keys[i] +
                "\nAddress = 10.66.66." + (i + 2) + "/32\nDNS = 1.1.1.1\nMTU = 1420\n\n[Peer]\nPublicKey = " +
                keys[0] + "\nAllowedIPs = 0.0.0.0/0\nEndpoint = example.com:51821\nPersistentKeepalive = 25\n";
            Console.WriteLine("__WG_PROFILE__" + names[i] + ":" +
                Convert.ToBase64String(Encoding.UTF8.GetBytes(content)));
        }
        return Environment.GetEnvironmentVariable("WG_FIXTURE_FAIL") == "1" ? 39 : 0;
    }
}
