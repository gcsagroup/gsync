import java.io.*;
import java.security.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.*;

// 上层从相同向量提取 JSON 字段。这里独立验证 JVM 的派生、AAD、密文布局与正文摘要。
class FormatCheck {
    static byte[] open(byte[] key, byte[] sealed, String aad) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,sealed,0,12));
        cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        return cipher.doFinal(sealed,12,sealed.length-12);
    }
    public static void main(String[] args) throws Exception {
        Properties input = new Properties();
        input.load(System.in);
        var base64 = Base64.getDecoder();
        var spec = new PBEKeySpec(input.getProperty("password").toCharArray(),
            base64.decode(input.getProperty("salt")),Integer.parseInt(input.getProperty("iterations")),256);
        var wrapping = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec);
        String prefix = input.getProperty("prefix");
        byte[] key = open(wrapping.getEncoded(),base64.decode(input.getProperty("passwordSlot")),prefix+"password");
        byte[] recovered = open(base64.decode(input.getProperty("recovery")),base64.decode(input.getProperty("recoverySlot")),prefix+"recovery");
        if (!MessageDigest.isEqual(key,recovered)) throw new IOException("恢复密钥不匹配");
        byte[] sealed = base64.decode(input.getProperty("sealedState"));
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(open(key,sealed,prefix+"state"));
        if (!HexFormat.of().formatHex(digest).equals(input.getProperty("clearStateSHA256"))) throw new IOException("正文摘要不匹配");
        sealed[sealed.length-1] ^= 1;
        try { open(key,sealed,prefix+"state"); throw new IOException("错误接受篡改"); }
        catch (AEADBadTagException expected) { System.out.println("JVM 解密、恢复密钥和篡改拒绝通过"); }
    }
}
