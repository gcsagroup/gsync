package org.gcsa.pbsync.android;

import android.app.Activity;
import android.content.SharedPreferences;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.hardware.fingerprint.FingerprintManager;
import android.os.Build;
import android.os.CancellationSignal;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.IOException;
import java.security.KeyStore;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class BiometricUnlock {
    private final Activity activity;
    private final SharedPreferences preferences;

    BiometricUnlock(Activity activity) {
        this.activity = activity;
        preferences = activity.getSharedPreferences("local-biometric-unlock", Activity.MODE_PRIVATE);
    }

    @SuppressWarnings("deprecation")
    boolean available() {
        if (Build.VERSION.SDK_INT >= 29) {
            BiometricManager manager = activity.getSystemService(BiometricManager.class);
            if (manager == null) return false;
            int result = Build.VERSION.SDK_INT >= 30
                ? manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                : manager.canAuthenticate();
            return result == BiometricManager.BIOMETRIC_SUCCESS;
        }
        FingerprintManager manager = activity.getSystemService(FingerprintManager.class);
        return manager != null && manager.hasEnrolledFingerprints();
    }

    boolean configured(boolean bookmarks) { return preferences.contains(alias(bookmarks)); }

    private String alias(boolean bookmarks) {
        return "org.gcsa.pbsync.bio.v1." + (bookmarks ? "bookmarks" : "vault");
    }

    private KeyStore keyStore() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        return store;
    }

    Cipher encryption(boolean bookmarks) throws Exception {
        String alias = alias(bookmarks);
        KeyGenParameterSpec.Builder options = new KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true).setInvalidatedByBiometricEnrollment(true);
        if (Build.VERSION.SDK_INT >= 30) {
            options.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG);
        }
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(options.build());
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, generator.generateKey());
        return cipher;
    }

    Cipher decryption(boolean bookmarks) throws Exception {
        String alias = alias(bookmarks);
        byte[] nonce = Base64.getDecoder().decode(preferences.getString(alias + ".nonce", ""));
        SecretKey key = (SecretKey) keyStore().getKey(alias, null);
        if (key == null || nonce.length != 12) throw new IOException("本机生物识别密钥不可用。");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce));
        return cipher;
    }

    void save(boolean bookmarks, Cipher cipher, byte[] key) throws Exception {
        String alias = alias(bookmarks);
        Base64.Encoder encoder = Base64.getEncoder();
        if (!preferences.edit().putString(alias, encoder.encodeToString(cipher.doFinal(key)))
                .putString(alias + ".nonce", encoder.encodeToString(cipher.getIV())).commit()) {
            throw new IOException("无法保存本机生物识别设置。");
        }
    }

    byte[] read(boolean bookmarks, Cipher cipher) throws Exception {
        return cipher.doFinal(Base64.getDecoder().decode(preferences.getString(alias(bookmarks), "")));
    }

    void remove(boolean bookmarks) throws Exception {
        String alias = alias(bookmarks);
        keyStore().deleteEntry(alias);
        if (!preferences.edit().remove(alias).remove(alias + ".nonce").commit()) {
            throw new IOException("无法清除本机生物识别设置。");
        }
    }

    void authenticate(String title, Cipher cipher, CancellationSignal signal,
                      Runnable cancel, BiometricPrompt.AuthenticationCallback callback) {
        BiometricPrompt.Builder prompt = new BiometricPrompt.Builder(activity).setTitle(title)
            .setNegativeButton("取消", activity.getMainExecutor(), (dialog, button) -> cancel.run());
        if (Build.VERSION.SDK_INT >= 30) {
            prompt.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG);
        }
        prompt.build().authenticate(new BiometricPrompt.CryptoObject(cipher), signal,
            activity.getMainExecutor(), callback);
    }
}
