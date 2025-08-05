#!/bin/bash
set -e

echo "=== Запуск pre-build.sh ==="

OPENVPN_DIR="padavan-ng/trunk/user/openvpn/openvpn-2.6.13"

# Проверяем наличие каталога
if [ ! -d "$OPENVPN_DIR" ]; then
    echo "Ошибка: не найден каталог $OPENVPN_DIR"
    exit 1
fi

echo "Применяю XOR-патч к OpenVPN 2.6.13..."

patch -d "$OPENVPN_DIR" -p1 <<'EOF'
--- src/openvpn/forward.c
+++ src/openvpn/forward.c
@@ -750,7 +750,10 @@
     status = link_socket_read(c->c2.link_socket,
                               &c->c2.buf,
-                              &c->c2.from);
+                              &c->c2.from,
+                              c->options.ce.xormethod,
+                              c->options.ce.xormask,
+                              c->options.ce.xormasklen);

--- src/openvpn/options.c
+++ src/openvpn/options.c
@@ -850,6 +850,9 @@
     o->resolve_retry_seconds = RESOLV_RETRY_INFINITE;
     o->resolve_in_advance = false;
     o->proto_force = -1;
+    o->ce.xormethod = 0;
+    o->ce.xormask = "\0";
+    o->ce.xormasklen = 1;

@@ -6100,6 +6103,36 @@
     else if (streq(p[0], "scramble"))
     {
         VERIFY_PERMISSION(OPT_P_GENERAL|OPT_P_CONNECTION);
+        if (streq(p[1], "xormask"))
+        {
+            options->ce.xormethod = 1;
+            options->ce.xormask = p[2];
+            options->ce.xormasklen = strlen(options->ce.xormask);
+        }
+        else if (streq(p[1], "xorptrpos"))
+        {
+            options->ce.xormethod = 2;
+        }
+        else if (streq(p[1], "reverse"))
+        {
+            options->ce.xormethod = 3;
+        }
+        else if (streq(p[1], "obfuscate"))
+        {
+            options->ce.xormethod = 4;
+            options->ce.xormask = p[2];
+            options->ce.xormasklen = strlen(options->ce.xormask);
+        }
+        else
+        {
+            options->ce.xormethod = 1;
+            options->ce.xormask = p[1];
+            options->ce.xormasklen = strlen(options->ce.xormask);
+        }
+    }

--- src/openvpn/options.h
+++ src/openvpn/options.h
@@ -120,6 +120,9 @@
     int connect_retry_seconds;
     int connect_retry_seconds_max;
     int connect_timeout;
+    int xormethod;
+    const char *xormask;
+    int xormasklen;

--- src/openvpn/socket.c
+++ src/openvpn/socket.c
@@ -60,6 +60,47 @@
     IPv6_TCP_HEADER_SIZE,
 };

+int buffer_mask(struct buffer *buf, const char *mask, int xormasklen)
+{
+    int i;
+    uint8_t *b;
+    for (i = 0, b = BPTR(buf); i < BLEN(buf); i++, b++)
+    {
+        *b = *b ^ mask[i % xormasklen];
+    }
+    return BLEN(buf);
+}
+
+int buffer_xorptrpos(struct buffer *buf)
+{
+    int i;
+    uint8_t *b;
+    for (i = 0, b = BPTR(buf); i < BLEN(buf); i++, b++)
+    {
+        *b = *b ^ (i + 1);
+    }
+    return BLEN(buf);
+}
+
+int buffer_reverse(struct buffer *buf)
+{
+    int len = BLEN(buf);
+    if (len > 2)
+    {
+        int i;
+        uint8_t *b_start = BPTR(buf) + 1;
+        uint8_t *b_end = BPTR(buf) + (len - 1);
+        uint8_t tmp;
+        for (i = 0; i < (len - 1) / 2; i++, b_start++, b_end--)
+        {
+            tmp = *b_start;
+            *b_start = *b_end;
+            *b_end = tmp;
+        }
+    }
+    return len;
+}
EOF

echo "XOR-патч успешно применён!"
