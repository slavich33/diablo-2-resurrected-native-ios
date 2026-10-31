// Mac/desktop development reference only; not included in the native game.
// Reads the owner's samples in memory. Never writes a save or contacts a server.
using System.Text.Json;
using D2SSharp.Data;
using D2SSharp.Model;

if (args.Length is < 1 or > 2 || !Directory.Exists(args[0]))
{
    Console.Error.WriteLine("Usage: SaveReference <save-directory> [version-105-table-directory]");
    return 2;
}

var samples = new List<object>();
bool passed = true;
try
{
    var tables = args.Length == 2 ? new TxtFileExternalData(args[1], version: 105) : null;
    var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint };
    foreach (var file in Directory.EnumerateFiles(args[0], "*", options).Order(StringComparer.Ordinal))
    {
        var extension = Path.GetExtension(file).ToLowerInvariant();
        if (extension is not (".d2s" or ".d2i")) continue;
        try
        {
            if (new FileInfo(file).Length > 16 * 1024 * 1024) throw new InvalidDataException();
            var bytes = File.ReadAllBytes(file);
            byte[] output = extension == ".d2s"
                ? (tables is null ? D2Save.Read(bytes) : D2Save.Read(bytes, tables)).ToBytes()
                : (tables is null ? D2StashSave.Read(bytes) : D2StashSave.Read(bytes, tables)).ToBytes();
            var identical = bytes.AsSpan().SequenceEqual(output);
            passed &= identical;
            samples.Add(new { extension, inputBytes = bytes.Length, outputBytes = output.Length, byteIdentical = identical, readWriteSucceeded = true });
        }
        catch (Exception error)
        {
            passed = false;
            samples.Add(new { extension, readWriteSucceeded = false, errorType = error.GetType().Name });
        }
    }
}
catch (Exception error)
{
    Console.Error.WriteLine("Reference setup failed: " + error.GetType().Name);
    return 2;
}
if (samples.Count == 0) passed = false;
Console.WriteLine(JsonSerializer.Serialize(new {
    reference = "D2SSharp 0.0.22", tables = args.Length == 2 ? "external v105" : "embedded",
    savedFilesWritten = 0, serverContacted = false, passed, samples
}, new JsonSerializerOptions { WriteIndented = true }));
return passed ? 0 : 1;
