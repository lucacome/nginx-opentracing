# syntax=docker/dockerfile:1.3
FROM nginx:1.21.1 as build-base

RUN apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y \
    autoconf \
    autogen \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    git \
    golang \
    libc-ares-dev \
    libcurl4-openssl-dev \
    libprotobuf-dev \
    libre2-dev \
    libssl-dev \
    libtool \
    libz-dev \
    pkg-config \
    protobuf-compiler \
    wget \
    zlib1g-dev


### Build gRPC
FROM build-base as grpc
ARG GRPC_VERSION=v1.40.x

RUN git clone --depth 1 -b $GRPC_VERSION https://github.com/grpc/grpc \
    && cd grpc\
    # Get absl
    && git submodule update --depth 1 --init -- "third_party/abseil-cpp" \
    # Get protobuf
    && git submodule update --depth 1 --init -- "third_party/protobuf" \
    && mkdir .build && cd .build \
    && cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DgRPC_INSTALL=ON \
    -DgRPC_BUILD_TESTS=OFF \
    -DgRPC_ABSL_PROVIDER=module     \
    -DgRPC_CARES_PROVIDER=package    \
    -DgRPC_PROTOBUF_PROVIDER=module \
    -DgRPC_RE2_PROVIDER=package      \
    -DgRPC_SSL_PROVIDER=package      \
    -DgRPC_ZLIB_PROVIDER=package \
    .. \
    && make -j$(nproc) install


### Build opentracing-cpp
FROM build-base as opentracing-cpp
ARG OPENTRACING_CPP_VERSION=v1.6.0

RUN git clone --depth 1 -b $OPENTRACING_CPP_VERSION https://github.com/opentracing/opentracing-cpp.git \
    && cd opentracing-cpp \
    && mkdir .build && cd .build \
    && cmake -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_MOCKTRACER=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_TESTING=OFF .. \
    && make -j$(nproc) install


### Build zipkin-cpp-opentracing
FROM opentracing-cpp as zipkin-cpp-opentracing
ARG ZIPKIN_CPP_VERSION=master

RUN apt-get --no-install-recommends --no-install-suggests -y install libcurl4-gnutls-dev

RUN git clone --depth 1 -b $ZIPKIN_CPP_VERSION https://github.com/rnburn/zipkin-cpp-opentracing.git \
    && cd zipkin-cpp-opentracing \
    && mkdir .build && cd .build \
    && cmake -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_PLUGIN=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_TESTING=OFF .. \
    && make -j$(nproc) install


### Build Jaeger cpp-client
FROM opentracing-cpp as jaeger-cpp-client
ARG JAEGER_CPP_VERSION=v0.7.0

RUN git clone --depth 1 -b $JAEGER_CPP_VERSION https://github.com/jaegertracing/jaeger-client-cpp \
    && cd jaeger-client-cpp \
    && mkdir .build \
    && cd .build \
    && cmake -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DJAEGERTRACING_BUILD_EXAMPLES=OFF \
    -DJAEGERTRACING_BUILD_CROSSDOCK=OFF \
    -DJAEGERTRACING_COVERAGE=OFF \
    -DJAEGERTRACING_PLUGIN=ON \
    -DHUNTER_CONFIGURATION_TYPES=Release \
    -DJAEGERTRACING_WITH_YAML_CPP=ON .. \
    && make -j$(nproc) install \
    && export HUNTER_INSTALL_DIR=$(cat _3rdParty/Hunter/install-root-dir) \
    && mkdir /hunter \
    && cp -r $HUNTER_INSTALL_DIR/lib /hunter/ \
    && cp -r $HUNTER_INSTALL_DIR/include /hunter/ \
    && mv libjaegertracing_plugin.so /usr/local/lib/libjaegertracing_plugin.so


### Build dd-opentracing-cpp
FROM opentracing-cpp as dd-opentracing-cpp
ARG DATADOG_VERSION=master

RUN git clone --depth 1 -b $DATADOG_VERSION https://github.com/DataDog/dd-opentracing-cpp.git \
    && cd dd-opentracing-cpp \
    && scripts/install_dependencies.sh not-opentracing not-curl not-zlib \
    && mkdir .build && cd .build \
    && cmake -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_PLUGIN=ON \
    -DBUILD_TESTING=OFF .. \
    && make -j$(nproc) install


### Build nginx-opentracing modules
FROM build-base as build-nginx

COPY --from=jaeger-cpp-client /hunter /hunter

COPY . /src

RUN echo "deb-src http://nginx.org/packages/mainline/debian/ stretch nginx" >> /etc/apt/sources.list \
    && apt-get update \
    && apt-get build-dep -y nginx

RUN wget -O nginx-release-${NGINX_VERSION}.tar.gz https://github.com/nginx/nginx/archive/release-${NGINX_VERSION}.tar.gz \
    && tar zxf nginx-release-${NGINX_VERSION}.tar.gz \
    && cd nginx-release-${NGINX_VERSION} \
    && auto/configure \
    --with-compat \
    --add-dynamic-module=/src/opentracing \
    --with-cc-opt="-I/hunter/include" \
    --with-ld-opt="-L/hunter/lib" \
    --with-debug \
    && make modules \
    && cp objs/ngx_http_opentracing_module.so /usr/lib/nginx/modules/


### Build final image
FROM nginx:1.21.1 as final

COPY --from=build-nginx /usr/lib/nginx/modules/ /usr/lib/nginx/modules/
COPY --from=dd-opentracing-cpp /usr/local/lib/ /usr/local/lib/
COPY --from=jaeger-cpp-client /usr/local/lib/ /usr/local/lib/
COPY --from=zipkin-cpp-opentracing /usr/local/lib/ /usr/local/lib/
COPY --from=opentracing-cpp /usr/local/lib/ /usr/local/lib/
COPY --from=grpc /usr/local/lib/ /usr/local/lib/

STOPSIGNAL SIGTERM
