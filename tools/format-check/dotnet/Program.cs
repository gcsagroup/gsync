// 仅验算仓库的合成向量。完整应用还需验证版本链、类型与资源上限。
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

string folder = args[0];
using var expectedFile = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(folder, "expected.json")));
var expected = expectedFile.RootElement;
using var archiveFile = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(folder, "synthetic-v1.pbsync")));
var archive = archiveFile.RootElement;
var head = archive.GetProperty("header");
string prefix = $"PBsync|{head.GetProperty("format")}|{head.GetProperty("spaceID").GetString()!.ToLowerInvariant()}|{head.GetProperty("keyEpoch")}|";
byte[] Open(byte[] key, byte[] sealedBytes, string purpose) {
    using var aes = new AesGcm(key,16);
    var output = new byte[sealedBytes.Length-28];
    aes.Decrypt(sealedBytes.AsSpan(0,12), sealedBytes.AsSpan(12,output.Length), sealedBytes.AsSpan(12+output.Length), output, Encoding.UTF8.GetBytes(prefix+purpose));
    return output;
}

byte[] passwordKey = Rfc2898DeriveBytes.Pbkdf2(expected.GetProperty("password").GetString()!,
    head.GetProperty("salt").GetBytesFromBase64(),head.GetProperty("iterations").GetInt32(),HashAlgorithmName.SHA256,32);
byte[] key = Open(passwordKey,head.GetProperty("passwordSlot").GetBytesFromBase64(),"password");
byte[] recovered = Open(expected.GetProperty("recovery").GetBytesFromBase64(),head.GetProperty("recoverySlot").GetBytesFromBase64(),"recovery");
if (!CryptographicOperations.FixedTimeEquals(key,recovered)) throw new InvalidDataException("恢复密钥不匹配");
byte[] sealedState = archive.GetProperty("sealedState").GetBytesFromBase64();
byte[] state = Open(key,sealedState,"state");
if (Convert.ToHexString(SHA256.HashData(state)).ToLowerInvariant() != expected.GetProperty("clearStateSHA256").GetString())
    throw new InvalidDataException("正文摘要不匹配");
sealedState[^1] ^= 1;
try { Open(key,sealedState,"state"); throw new InvalidDataException("错误接受篡改"); }
catch (CryptographicException) { Console.WriteLine(".NET 备份解密、恢复密钥和篡改拒绝通过"); }
