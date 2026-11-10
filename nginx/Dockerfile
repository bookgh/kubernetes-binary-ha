FROM rockylinux:9 AS nginx-builder
ARG NGINX_VERSION=1.30.6
ARG NGINX_SHA256=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
# Rocky Linux 9 基础镜像预装 curl-minimal；不要安装与其冲突的 curl 软件包。
RUN dnf -y install gcc make glibc-devel \
 && dnf clean all \
 && rm -rf /var/cache/dnf
WORKDIR /usr/local/src
RUN curl -fL --retry 4 --retry-all-errors "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz \
 && echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c - \
 && tar -xzf nginx.tar.gz \
 && cd "nginx-${NGINX_VERSION}" \
 && ./configure --prefix=/usr/local/nginx --sbin-path=/usr/local/nginx/sbin/nginx \
      --conf-path=/etc/nginx/nginx.conf --pid-path=/run/nginx-k8s-api.pid \
      --error-log-path=/var/log/nginx-k8s-api/error.log --without-http --with-stream --with-threads \
      --with-cc-opt="-O2 -fstack-protector-strong" --with-ld-opt="-Wl,-z,relro -Wl,-z,now" \
 && make -j"$(nproc)" && make install \
 && mkdir -p /out && cp /usr/local/nginx/sbin/nginx /out/nginx \
 && chmod 0755 /out/nginx && /out/nginx -V
FROM scratch AS artifact
COPY --from=nginx-builder /out/nginx /nginx
CMD ["/nginx", "-V"]
