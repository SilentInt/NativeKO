package com.nativeko;

import android.app.Activity;
import android.content.res.AssetManager;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * NativeKO: one-tap launcher for the native (framebuffer/evdev) KOReader
 * build.
 *
 * The APK embeds the complete KOReader Lua module, the native libraries and
 * the launcher scripts. On first start they are extracted into the app's
 * private data directory; every start then runs run-native.sh as root via
 * su. Stopping zygote/SurfaceFlinger during startup kills this Activity,
 * which is expected: the native process owns the screen from then on, and
 * run-native.sh restarts the Android framework when KOReader exits.
 */
public class MainActivity extends Activity {
    private static final String TAG = "NativeKO";

    /** Bump this whenever the embedded assets change. */
    private static final String ASSET_VERSION = "23";

    private TextView status;
    private final Handler handler = new Handler();
    private volatile int extractedFiles = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        status = new TextView(this);
        status.setTextSize(18f);
        status.setPadding(48, 96, 48, 48);
        status.setTextColor(Color.BLACK);
        status.setBackgroundColor(Color.WHITE);
        setContentView(status);

        setStatus("NativeKO\n\n正在检查 root 权限…");

        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                launchNativeKo();
            }
        }, "nativeko-launch");
        t.start();
    }

    private void setStatus(final String text) {
        handler.post(new Runnable() {
            @Override
            public void run() {
                status.setText(text);
            }
        });
    }

    /** Run a command through su and return its merged output. */
    private String runSu(String command) {
        StringBuilder out = new StringBuilder();
        try {
            Process p = new ProcessBuilder("su", "-c", command)
                    .redirectErrorStream(true)
                    .start();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = r.readLine()) != null) {
                out.append(line).append('\n');
            }
            r.close();
            p.waitFor();
        } catch (Exception e) {
            Log.w(TAG, "su failed: " + e);
            out.append("ERROR: ").append(e);
        }
        return out.toString();
    }

    private void launchNativeKo() {
        String id = runSu("id");
        if (!id.contains("uid=0")) {
            setStatus("需要 root 权限。\n\n请授予 NativeKO root 权限后重新打开。\n\n" + id.trim());
            return;
        }

        // Never start a second instance on top of a running one.
        String ps = runSu("ps | grep \"[k]oreader-native\"");
        if (ps.trim().length() > 0) {
            setStatus("NativeKO 已经在运行。");
            return;
        }

        File base = getFilesDir();
        File koDir = new File(base, "ko");
        File nativeDir = new File(base, "native");
        File marker = new File(base, ".asset_version");

        String haveVersion = readText(marker);
        if (!ASSET_VERSION.equals(haveVersion)) {
            if (koDir.exists() || nativeDir.exists()) {
                // KOReader runs as root and owns some of these files.
                setStatus("正在清理旧版本文件…");
                runSu("rm -rf '" + koDir.getAbsolutePath() + "' '" + nativeDir.getAbsolutePath() + "'");
            }
            setStatus("正在解压 KOReader 文件…\n首次启动约需 1 分钟，请勿退出。");
            try {
                extractedFiles = 0;
                extractZipAsset("ko.zip", koDir);
                extractZipAsset("native.zip", nativeDir);
                writeText(marker, ASSET_VERSION);
            } catch (IOException e) {
                Log.e(TAG, "extract failed", e);
                setStatus("解压失败：" + e);
                return;
            }
        }

        // Executable bits: the app owns these files, but the native process
        // runs as root and still needs a set x bit to exec/mmap PROT_EXEC.
        File bin = new File(nativeDir, "koreader-native");
        if (!bin.isFile()) {
            setStatus("启动器缺失：" + bin);
            return;
        }
        bin.setExecutable(true, false);
        String[] scripts = { "run-native.sh", "restore-android.sh",
                "session.sh", "start-session.sh", "detach",
                "drivers/wifi/udhcpc.sh" };
        for (String s : scripts) {
            new File(nativeDir, s).setExecutable(true, false);
        }
        File[] libs = new File(koDir, "libs").listFiles();
        if (libs != null) {
            for (File f : libs) {
                if (f.getName().endsWith(".so")) {
                    f.setExecutable(true, false);
                }
            }
        }

        setStatus("正在启动 Native KOReader…");
        // The build script writes the device profile id next to the scripts;
        // run-native.sh reads KO_NATIVE_PROFILE_ID so the same launcher works
        // for any packaged profile.
        String profileId = readText(new File(nativeDir, "profile.id"));
        if (profileId == null || profileId.trim().length() == 0) {
            profileId = "notesl";
        }
        profileId = profileId.trim();
        File detach = new File(nativeDir, "detach");
        detach.setExecutable(true, false);
        String launcher = detach.isFile()
                ? "'" + detach.getAbsolutePath() + "' sh '"
                    + nativeDir.getAbsolutePath() + "/run-native.sh'"
                : "setsid sh '" + nativeDir.getAbsolutePath()
                    + "/run-native.sh' &";
        String cmd = "cd '" + koDir.getAbsolutePath() + "' && "
                + "KO_HOME='" + koDir.getAbsolutePath() + "' "
                + "KO_NATIVE_DIR='" + nativeDir.getAbsolutePath() + "' "
                + "KO_NATIVE_PROFILE_ID='" + profileId + "' "
                + launcher
                + " > '" + nativeDir.getAbsolutePath() + "/run.log' 2>&1 < /dev/null";
        String out = runSu(cmd);
        if (out.contains("ERROR")) {
            setStatus("启动失败：\n" + out);
            return;
        }
        setStatus("正在启动 Native KOReader…\n\n屏幕即将切换，请稍候。");
    }

    /**
     * Extract one deflated zip asset (ko.zip / native.zip) in a single
     * streaming pass. Much faster than opening ~1000 individual
     * AssetManager streams, and keeps the APK compressed.
     */
    private void extractZipAsset(String assetName, File destRoot) throws IOException {
        AssetManager am = getAssets();
        InputStream raw = new BufferedInputStream(am.open(assetName), 128 * 1024);
        ZipInputStream zin = new ZipInputStream(raw);
        byte[] buf = new byte[128 * 1024];
        try {
            ZipEntry entry;
            while ((entry = zin.getNextEntry()) != null) {
                String name = entry.getName();
                if (name.contains("..")) {
                    continue;
                }
                File out = new File(destRoot, name);
                if (entry.isDirectory()) {
                    out.mkdirs();
                    continue;
                }
                File parent = out.getParentFile();
                if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
                    throw new IOException("cannot create " + parent);
                }
                FileOutputStream fos = new FileOutputStream(out);
                try {
                    int n;
                    while ((n = zin.read(buf)) > 0) {
                        fos.write(buf, 0, n);
                    }
                } finally {
                    fos.close();
                }
                zin.closeEntry();

                extractedFiles++;
                if ((extractedFiles % 200) == 0) {
                    setStatus("正在解压 KOReader 文件…\n已解压 " + extractedFiles + " 个文件，请勿退出。");
                }
            }
        } finally {
            zin.close();
        }
    }

    private static String readText(File f) {
        if (!f.isFile()) {
            return null;
        }
        try {
            FileInputStream in = new FileInputStream(f);
            try {
                byte[] buf = new byte[(int) f.length()];
                int n = in.read(buf);
                return n > 0 ? new String(buf, 0, n, "UTF-8") : "";
            } finally {
                in.close();
            }
        } catch (IOException e) {
            return null;
        }
    }

    private static void writeText(File f, String text) throws IOException {
        FileOutputStream out = new FileOutputStream(f);
        try {
            out.write(text.getBytes("UTF-8"));
        } finally {
            out.close();
        }
    }
}
