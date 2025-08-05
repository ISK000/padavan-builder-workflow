#!/bin/bash
set -e

echo "=== Запуск pre-build.sh ==="

# Находим актуальную директорию OpenVPN
OPENVPN_DIR=$(find padavan-ng/trunk/user/openvpn -maxdepth 1 -type d -name "openvpn-2.*" | sort | tail -1)

if [ ! -d "$OPENVPN_DIR" ]; then
    echo "Ошибка: не найден каталог OpenVPN внутри padavan-ng/trunk/user/openvpn/"
    exit 1
fi

echo "Найден OpenVPN: $OPENVPN_DIR"
echo "Применяю XOR-патч..."

patch -d "$OPENVPN_DIR" -p1 <<'EOF'
diff -Naur src/openvpn/forward.c src/openvpn/forward.c
--- src/openvpn/forward.c
+++ src/openvpn/forward.c
@@ -729,7 +729,10 @@
     status = link_socket_read(c->c2.link_socket,
                               &c->c2.buf,
-                              &c->c2.from);
+                              &c->c2.from,
+                              c->options.ce.xormethod,
+                              c->options.ce.xormask,
+                              c->options.ce.xormasklen);

     if (socket_connection_reset(c->c2.link_socket, status))
     {
@@ -1374,7 +1377,10 @@
                 /* Send packet */
                 size = link_socket_write(c->c2.link_socket,
                                          &c->c2.to_link,
-                                         to_addr);
+                                         to_addr,
+                                         c->options.ce.xormethod,
+                                         c->options.ce.xormask,
+                                         c->options.ce.xormasklen);

                 /* Undo effect of prepend */
                 link_socket_write_post_size_adjust(&size, size_delta, &c->c2.to_link);
diff -Naur src/openvpn/options.c src/openvpn/options.c
--- src/openvpn/options.c
+++ src/openvpn/options.c
@@ -811,6 +811,9 @@
     o->resolve_retry_seconds = RESOLV_RETRY_INFINITE;
     o->resolve_in_advance = false;
     o->proto_force = -1;
+    o->ce.xormethod = 0;
+    o->ce.xormask ="\0";
+    o->ce.xormasklen = 1;
 #ifdef ENABLE_OCC
     o->occ = true;
 #endif
@@ -972,6 +975,9 @@
     setenv_str_i(es, "local_port", e->local_port, i);
     setenv_str_i(es, "remote", e->remote, i);
     setenv_str_i(es, "remote_port", e->remote_port, i);
+    setenv_int_i(es, "xormethod", e->xormethod, i);
+    setenv_str_i(es, "xormask", e->xormask, i);
+    setenv_int_i(es, "xormasklen", e->xormasklen, i);
diff -Naur src/openvpn/options.h src/openvpn/options.h
--- src/openvpn/options.h
+++ src/openvpn/options.h
@@ -101,6 +101,9 @@
     int connect_retry_seconds;
     int connect_retry_seconds_max;
     int connect_timeout;
+    int xormethod;
+    const char *xormask;
+    int xormasklen;
diff -Naur src/openvpn/socket.c src/openvpn/socket.c
--- src/openvpn/socket.c
+++ src/openvpn/socket.c
@@ -54,6 +54,47 @@
     IPv6_TCP_HEADER_SIZE,
 };

+int buffer_mask (struct buffer *buf, const char *mask, int xormasklen)
+{
+    int i;
+    uint8_t *b;
+    for (i = 0, b = BPTR (buf); i < BLEN(buf); i++, b++)
+    {
+        *b = *b ^ mask[i % xormasklen];
+    }
+    return BLEN (buf);
+}
+
+int buffer_xorptrpos (struct buffer *buf)
+{
+    int i;
+    uint8_t *b;
+    for (i = 0, b = BPTR (buf); i < BLEN(buf); i++, b++)
+    {
+        *b = *b ^ i+1;
+    }
+    return BLEN (buf);
+}
+
+int buffer_reverse (struct buffer *buf)
+{
+    int len = BLEN(buf);
+    if (  len > 2  )
+    {
+        int i;
+        uint8_t *b_start = BPTR (buf) + 1;
+        uint8_t *b_end   = BPTR (buf) + (len - 1);
+        uint8_t tmp;
+        for (i = 0; i < (len-1)/2; i++, b_start++, b_end--)
+        {
+            tmp = *b_start;
+            *b_start = *b_end;
+            *b_end = tmp;
+        }
+    }
+    return len;
+}
diff -Naur src/openvpn/socket.h src/openvpn/socket.h
--- src/openvpn/socket.h
+++ src/openvpn/socket.h
@@ -248,6 +248,10 @@
 #endif
 };
+
+int buffer_mask (struct buffer *buf, const char *xormask, int xormasklen);
+int buffer_xorptrpos (struct buffer *buf);
+int buffer_reverse (struct buffer *buf);
EOF

echo "XOR-патч успешно применён!"
