package org.gcsa.pbsync;

import java.io.StringReader;
import java.io.IOException;
import java.net.URI;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import javax.xml.parsers.DocumentBuilderFactory;
import okhttp3.Credentials;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import org.w3c.dom.NodeList;
import org.xml.sax.InputSource;

import static java.nio.charset.StandardCharsets.UTF_8;
import static java.util.concurrent.TimeUnit.SECONDS;

public final class DavStorage {
    private static final MediaType BINARY = MediaType.get("application/octet-stream");
    private static final RequestBody FIND = RequestBody.create(
        "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>",
        MediaType.get("application/xml"));
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
        .followRedirects(false).followSslRedirects(false).callTimeout(30, SECONDS).build();

    private final HttpUrl root;
    private final String authorization;

    public DavStorage(String address, String username, char[] password) throws IOException {
        HttpUrl url = HttpUrl.parse(address.trim());
        if (url == null || !url.username().isEmpty() || !url.password().isEmpty()
                || url.query() != null || url.fragment() != null
                || (!url.isHttps() && !Arrays.asList("127.0.0.1", "localhost", "::1").contains(url.host()))) {
            throw new IOException("请输入 HTTPS WebDAV 目录。");
        }
        root = url.encodedPath().endsWith("/") ? url : url.newBuilder().addPathSegment("").build();
        authorization = Credentials.basic(username, new String(password), UTF_8);
    }

    public Set<String> list() throws Exception {
        Request request = request(root).header("Depth", "1").method("PROPFIND", FIND).build();
        byte[] bytes = fetch(request, 8 * 1024 * 1024);
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        String xml = new String(bytes, UTF_8);
        // 先按 UTF-8 解码为字符，再拒绝 DTD，避免外部实体及其他编码绕过检查。
        if (xml.contains("<!DOCTYPE")) throw new IOException("WebDAV 清单含无效声明。");
        NodeList hrefs = factory.newDocumentBuilder().parse(new InputSource(new StringReader(xml)))
            .getElementsByTagNameNS("DAV:", "href");
        URI base = root.uri();
        Set<String> names = new HashSet<>();
        for (int i = 0; i < hrefs.getLength(); i++) {
            URI item = base.resolve(hrefs.item(i).getTextContent().trim());
            if (!base.getScheme().equals(item.getScheme()) ||
                    !base.getRawAuthority().equalsIgnoreCase(item.getRawAuthority()) ||
                    item.getQuery() != null || item.getFragment() != null ||
                    !item.getPath().startsWith(base.getPath())) continue;
            String name = item.getPath().substring(base.getPath().length());
            if (name.equals("space.pbsync") || SpaceSession.isObjectName(name)) names.add(name);
        }
        return names;
    }

    public byte[] read(String name) throws IOException {
        return fetch(request(object(name)).get().build(), SpaceSession.MAX_BYTES);
    }

    // 版本对象只允许创建，写完后回读验证服务端实际持久化的字节。
    public boolean create(String name, byte[] bytes) throws IOException {
        Request put = request(object(name)).header("If-None-Match", "*")
            .put(RequestBody.create(bytes, BINARY)).build();
        try (Response response = HTTP.newCall(put).execute()) {
            if (response.code() == 409 || response.code() == 412) return false;
            check(response);
        }
        if (!Arrays.equals(read(name), bytes)) throw new IOException("远端写入后的校验失败。");
        return true;
    }

    private Request.Builder request(HttpUrl url) {
        return new Request.Builder().url(url).header("Authorization", authorization);
    }

    private HttpUrl object(String name) throws IOException {
        if (!name.equals("space.pbsync") && !SpaceSession.isObjectName(name)) {
            throw new IOException("远端文件名无效。");
        }
        return root.newBuilder().addPathSegment(name).build();
    }

    private static byte[] fetch(Request request, int limit) throws IOException {
        try (Response response = HTTP.newCall(request).execute()) {
            check(response);
            if (response.body() == null) throw new IOException("WebDAV 响应缺少正文。");
            return SpaceSession.readLimited(response.body().byteStream(), limit);
        }
    }

    private static void check(Response response) throws IOException {
        if (!response.isSuccessful()) throw new IOException("WebDAV 请求失败（" + response.code() + "）。");
    }
}
