#!/usr/bin/env bash
#
# da-php-build.sh - Build PHP 8.2 / 8.3 / 8.4 / 8.5 từ source trên CentOS 7 (DirectAdmin cũ)
#
# Ý tưởng: build dependency MỘT LẦN vào /opt/dabuild (OpenSSL 1.1.1, ICU 57, libxml2,
# curl, ...), sau đó build từng bản PHP vào /usr/local/phpXX theo đúng layout của
# DirectAdmin/CustomBuild. Không đụng vào CustomBuild, không chạy rewrite_confs,
# không đổi PHP chính.
#
# Tự nhận diện webserver (đọc 'webserver=' trong options.conf của CustomBuild):
#   apache | nginx | nginx_apache -> build PHP-FPM: php-fpmXX, sockets/, unit systemd
#   openlitespeed | litespeed     -> build lsphp: bin/lsphpXX (OLS tự khởi chạy, không có service)
#   Ép tay bằng MODE=fpm | lsphp | both   (both = build cả 2 SAPI trong 1 lần configure)
#
# Cách dùng:
#   ./da-php-build.sh check                   # kiểm tra máy + cho biết sẽ build kiểu nào, không thay đổi gì
#   ./da-php-build.sh detect                  # chỉ in webserver và chế độ build sẽ dùng
#   ./da-php-build.sh fetch [deps|all|8.x..]  # chỉ tải + kiểm sha256 source (chạy được trên máy Linux khác,
#                                             # rồi scp vào $SRC của server). Không gõ gì = all
#   ./da-php-build.sh setup                   # yum install các gói build còn thiếu
#   ./da-php-build.sh deps                    # build dependency (làm 1 lần)
#   ./da-php-build.sh php 8.4                 # build 1 bản (tự build deps nếu chưa có)
#   ./da-php-build.sh php 8.2 8.3 8.4 8.5     (hoặc: php all)
#   ./da-php-build.sh pack                    # đóng tar để mang sang server khác
#   ./da-php-build.sh unpack FILE.tar.gz      # giải nén + đăng ký systemd trên server đích
#
# Biến môi trường hay dùng:
#   SRC=/đường/dẫn   thư mục chứa tarball source (mặc định /usr/local/src/dabuild).
#                    Có thể trỏ thẳng vào payload/additions của bộ git cũ:
#                    SRC=/root/directadmin-php8-builder/payload/additions
#   JOBS=N           số luồng make (mặc định = min(số core, số GB RAM))
#   TOOLCHAIN=scl    dùng devtoolset (GCC mới) nếu đã cài; mặc định dùng GCC hệ thống
#   FORCE=1          cho phép ghi đè /usr/local/phpXX không do script này tạo
#   RESTART=1        fpm: enable + restart php-fpmXX | lsphp: kill lsphpXX để OLS khởi chạy lại
#   EXTRA_CONFIGURE="--enable-xxx ..."   thêm cờ configure cho PHP
#   MODE=auto|fpm|lsphp|both   chế độ build (mặc định auto = theo webserver)
#   WEB_GROUP=apache  group của webserver cho listen.group của FPM (mặc định tự đọc từ nginx.conf/httpd.conf)
#   DA_OPTIONS=...    đường dẫn options.conf của CustomBuild
#   CURL_OPTS="..."   cờ thêm cho curl, vd: -x http://proxy:3128  (curl cũng tự nhận https_proxy)
#   PHP_MIRRORS="https://mirror1/php https://mirror2/php"   mirror tải PHP thêm, được thử trước
#
# Nên chạy trong screen/tmux hoặc: nohup ./da-php-build.sh php all > run.log 2>&1 &

set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

DEPS=${DEPS:-/opt/dabuild}
SRC=${SRC:-/usr/local/src/dabuild}
WORK=${WORK:-/var/tmp/dabuild}
LOGS=${LOGS:-/root/dabuild-logs}
OUT=${OUT:-/root/dabuild-pack}
TOOLCHAIN=${TOOLCHAIN:-system}
EXTRA_CONFIGURE=${EXTRA_CONFIGURE:-}
FORCE=${FORCE:-0}
RESTART=${RESTART:-0}
MODE=${MODE:-auto}
WEB_GROUP=${WEB_GROUP:-}
DA_OPTIONS=${DA_OPTIONS:-/usr/local/directadmin/custombuild/options.conf}
CURL_OPTS=${CURL_OPTS:-}
PHP_MIRRORS=${PHP_MIRRORS:-}
DEP_FILES="zlib-1.3.1.tar.gz openssl-1.1.1w.tar.gz gmp-6.2.1.tar.xz libxml2-2.9.14.tar.xz curl-7.88.1.tar.xz onig-6.9.9.tar.gz libzip-1.2.0.tar.gz sqlite-autoconf-3450300.tar.gz icu4c-57_1-src.tgz"

declare -A PHPV=([8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12)
BRANCHES="8.2 8.3 8.4 8.5"

TOOL_PKGS="gcc gcc-c++ make perl patch tar xz curl pkgconfig ca-certificates"
DEV_PKGS="libpng-devel libjpeg-turbo-devel freetype-devel libwebp-devel libxslt-devel gettext-devel bzip2-devel systemd-devel"

# sha256 của source (lấy từ payload/SHA256SUMS của bộ git đã ghim)
SUMS='1dae31b2a7c1fe269de99c0c31bb488346aab3459b5ffca909d6938249ae415f  additions/curl-7.88.1.tar.xz
fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2  additions/gmp-6.2.1.tar.xz
ff8c67cb65949b1e7808f2359f2b80f722697048e90e7cfc382ec1fe229e9581  additions/icu4c-57_1-src.tgz
60d74a257d1ccec0475e749cba2f21559e48139efba6ff28224357c7c798dfee  additions/libxml2-2.9.14.tar.xz
6cf9840e427db96ebf3936665430bab204c9ebbd0120c326459077ed9c907d9f  additions/libzip-1.2.0.tar.gz
60162bd3b9fc6f4886d4c7a07925ffd374167732f55dce8c491bfd9cd818a6cf  additions/onig-6.9.9.tar.gz
cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8  additions/openssl-1.1.1w.tar.gz
9db4204f0a2d1911277ae832185e07bb4c3b3559772753a70d2968ca346d6910  additions/php-8.2.35.tar.gz
c93f3441f87f6ab156bef4432db215d7e61ca2c0183bb3a2aa28d9886ab59f53  additions/php-8.3.36.tar.gz
5bafed9994c1a49796b25b5f61c22c9183bfe046b6acc7b363842d03c77f972f  additions/php-8.4.27.tar.gz
81a0f450349e84b08eb43faa85f8a4c835684f3cc1c50471775d1317a046c525  additions/php-8.5.12.tar.gz
b2809ca53124c19c60f42bf627736eae011afdcc205bb48270a5ee9a38191531  additions/sqlite-autoconf-3450300.tar.gz
9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23  additions/zlib-1.3.1.tar.gz'

T0=$SECONDS
ts()   { printf '%02d:%02d' $(((SECONDS - T0) / 60)) $(((SECONDS - T0) % 60)); }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] CẢNH BÁO: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] LỖI: %s\n' "$(ts)" "$*" >&2; exit 1; }
trap 'die "Script dừng ở dòng $LINENO (lệnh: $BASH_COMMAND)"' ERR

calc_jobs() {
    local cores mem
    cores=$(nproc 2>/dev/null || echo 1)
    mem=$(awk '/MemTotal/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)
    [ "$mem" -ge 1 ] || mem=1
    [ "$cores" -le "$mem" ] && echo "$cores" || echo "$mem"
}
JOBS=${JOBS:-$(calc_jobs)}

# run "mô tả" lệnh...  -> ghi log vào $LOGS/$CUR.log, lỗi thì in 30 dòng cuối
CUR=main
run() {
    local what=$1; shift
    log "  - $what"
    mkdir -p "$LOGS"
    printf '\n### %s\n### %s\n' "$what" "$*" >>"$LOGS/$CUR.log"
    if ! "$@" >>"$LOGS/$CUR.log" 2>&1; then
        tail -n 30 "$LOGS/$CUR.log" >&2
        die "Lỗi ở bước '$what'. Log đầy đủ: $LOGS/$CUR.log"
    fi
}

# ---------------------------------------------------------------- kiểm tra máy
preflight() {
    [ "$(id -u)" = 0 ] || die "Cần chạy bằng root."
    if [ "${DABUILD_SKIP_OS:-0}" != 1 ]; then
        grep -q 'CentOS Linux release 7' /etc/centos-release 2>/dev/null || die "Script dành cho CentOS 7."
        [ "$(uname -m)" = x86_64 ] || die "Chỉ hỗ trợ x86_64."
    fi
    local c miss=()
    for c in gcc g++ make perl patch tar xz curl pkg-config sha256sum; do
        command -v "$c" >/dev/null 2>&1 || miss+=("lệnh:$c")
    done
    if command -v rpm >/dev/null 2>&1; then
        local p
        for p in $DEV_PKGS; do rpm -q "$p" >/dev/null 2>&1 || miss+=("$p"); done
        [ -r /etc/pki/tls/certs/ca-bundle.crt ] || miss+=("ca-certificates")
    fi
    if [ "${#miss[@]}" -gt 0 ]; then
        warn "Thiếu: ${miss[*]}"
        die "Chạy '$0 setup' (yum install) rồi chạy lại."
    fi
    mkdir -p "$WORK" "$LOGS" "$SRC"
    local free_gb
    free_gb=$(df -Pk "$WORK" | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')
    [ "$free_gb" -ge 8 ] || die "Cần tối thiểu ~8GB trống tại $WORK (đang có ${free_gb}GB)."
    log "Máy OK: $JOBS luồng make, ${free_gb}GB trống, SRC=$SRC"
}

setup_pkgs() {
    [ "$(id -u)" = 0 ] || die "Cần chạy bằng root."
    # shellcheck disable=SC2086
    yum install -y $TOOL_PKGS $DEV_PKGS
    log "Đã cài gói build. (Tùy chọn: yum install -y epel-release libsodium-devel để có ext sodium)"
}

toolchain() {
    if [ "$TOOLCHAIN" = scl ]; then
        local n found=0
        for n in 11 10 9 8 7; do
            if [ -r "/opt/rh/devtoolset-$n/enable" ]; then
                set +u; . "/opt/rh/devtoolset-$n/enable"; set -u
                log "Dùng devtoolset-$n"; found=1; break
            fi
        done
        [ "$found" = 1 ] || warn "Không thấy devtoolset, dùng GCC hệ thống."
    fi
    GCC_MAJOR=$(gcc -dumpversion | cut -d. -f1)
    log "GCC $(gcc -dumpversion)"
}

# ---------------------------------------------------------------- nhận diện webserver -> chế độ build
WEBSERVER=""; BUILD_MODE=""

detect_webserver() {
    local ws=""
    if [ -r "$DA_OPTIONS" ]; then
        ws=$(awk -F= '$1 == "webserver" {gsub(/[ \t\r]/, "", $2); print $2; exit}' "$DA_OPTIONS")
    fi
    if [ -z "$ws" ]; then
        if   [ -x /usr/local/lsws/bin/openlitespeed ]; then ws=openlitespeed
        elif [ -x /usr/local/lsws/bin/lshttpd ]; then ws=litespeed
        elif [ -x /usr/sbin/nginx ] && [ -x /usr/sbin/httpd ]; then ws=nginx_apache
        elif [ -x /usr/sbin/nginx ]; then ws=nginx
        elif [ -x /usr/sbin/httpd ]; then ws=apache
        else ws=unknown
        fi
        warn "Không đọc được 'webserver=' trong $DA_OPTIONS, đoán theo phần mềm đã cài: $ws"
    fi
    WEBSERVER=$ws
}

# group của webserver: PHP-FPM tạo socket với listen.group này để webserver đọc được
detect_web_group() {
    local g=${WEB_GROUP:-}
    if [ -z "$g" ]; then
        case "$WEBSERVER" in
            nginx)
                g=$(awk '$1 == "user" {gsub(/;/, ""); print ($3 != "" ? $3 : $2); exit}' /etc/nginx/nginx.conf 2>/dev/null || true) ;;
            *)  # apache và nginx_apache: Apache mới là bên nối vào socket FPM
                g=$(awk '$1 == "Group" {print $2; exit}' /etc/httpd/conf/httpd.conf 2>/dev/null || true) ;;
        esac
    fi
    [ -n "$g" ] || g=apache
    if ! getent group "$g" >/dev/null 2>&1; then
        warn "Group '$g' chưa có trên máy này (listen.group của FPM trỏ vào nó). Đặt WEB_GROUP=... nếu cần."
    fi
    WEB_GROUP=$g
}

resolve_mode() {
    detect_webserver
    local m=$MODE pm=""
    case "$m" in
        auto)
            case "$WEBSERVER" in
                openlitespeed|litespeed)   m=lsphp ;;
                apache|nginx|nginx_apache) m=fpm ;;
                *) m=fpm; warn "Không nhận diện được webserver '$WEBSERVER' -> mặc định build php-fpm (ép bằng MODE=fpm|lsphp|both)." ;;
            esac ;;
        fpm|lsphp|both) ;;
        *) die "MODE không hợp lệ: '$m' (dùng auto|fpm|lsphp|both)" ;;
    esac
    BUILD_MODE=$m
    if [ -r "$DA_OPTIONS" ]; then
        pm=$(awk -F= '/^php[0-9]+_mode=/ {gsub(/\r/, "", $2); printf "%s ", $2}' "$DA_OPTIONS")
    fi
    log "Webserver: $WEBSERVER | phpN_mode trong CustomBuild: ${pm:-?} | build: $BUILD_MODE"
    case "$BUILD_MODE:$pm" in
        lsphp:*php-fpm*) warn "Webserver là $WEBSERVER nhưng CustomBuild còn phpN_mode=php-fpm. OLS của DA chạy PHP bằng lsphp, nên bản build này mới dùng được khi DA đã ở chế độ lsphp." ;;
        fpm:*lsphp*)     warn "Webserver là $WEBSERVER nhưng CustomBuild có phpN_mode=lsphp. Nếu thực sự dùng lsphp hãy chạy với MODE=lsphp hoặc MODE=both." ;;
    esac
    if [ "$BUILD_MODE" != lsphp ]; then
        detect_web_group
        log "PHP-FPM: listen.group = $WEB_GROUP"
    fi
}

# ---------------------------------------------------------------- tải + kiểm tra source
url_for() {
    case "$1" in
        php-*)      local m
                    for m in $PHP_MIRRORS https://www.php.net/distributions https://secure.php.net/distributions https://museum.php.net/php8; do
                        printf '%s/%s\n' "${m%/}" "$1"
                    done ;;
        openssl-*)  echo "https://www.openssl.org/source/old/1.1.1/$1" ;;
        icu4c-*)    echo "https://github.com/unicode-org/icu/releases/download/release-57-1/$1" ;;
        libxml2-*)  echo "https://download.gnome.org/sources/libxml2/2.9/$1" ;;
        curl-*)     echo "https://curl.se/download/$1" ;;
        onig-*)     echo "https://github.com/kkos/oniguruma/releases/download/v6.9.9/$1" ;;
        libzip-*)   echo "https://libzip.org/download/$1" ;;
        sqlite-*)   echo "https://www.sqlite.org/2024/$1" ;;
        zlib-*)     echo "https://zlib.net/fossils/$1" ;;
        gmp-*)      echo "https://ftp.gnu.org/gnu/gmp/$1" ;;
        *)          return 1 ;;
    esac
}

sha_of()   { sha256sum "$1" | awk '{print $1}'; }
want_sha() { awk -v f="additions/$1" '$2 == f {print $1}' <<<"$SUMS"; }

# Ưu tiên curl 7.88 + OpenSSL 1.1.1 đã build trong $DEPS. Curl của CentOS 7 là 7.29 (NSS),
# hay báo "(35) incompatible or unsupported protocol version" với các site chỉ cho TLS mới.
pick_curl() {
    if [ -x "$DEPS/bin/curl" ] && "$DEPS/bin/curl" --version >/dev/null 2>&1; then
        printf '%s\n' "$DEPS/bin/curl"
    else
        command -v curl
    fi
}

# Nếu file đã được chép tay vào chỗ khác (scp vào /root, /tmp, thư mục hiện tại...)
# thì tự nhặt về $SRC, nhưng chỉ khi sha256 khớp.
find_local() {  # file sha256
    local f=$1 want=$2 d
    [ -n "$want" ] || return 1
    for d in "$PWD" "$(dirname "$0")" /root /tmp /usr/local/src; do
        [ "$d" != "$SRC" ] || continue
        [ -s "$d/$f" ] || continue
        if [ "$(sha_of "$d/$f")" != "$want" ]; then
            warn "Bỏ qua $d/$f (sai sha256)"; continue
        fi
        log "  - dùng file có sẵn: $d/$f"
        cp "$d/$f" "$SRC/$f"
        return 0
    done
    return 1
}

fetch() {
    local f=$1 u urls want got first curl_bin ok=0
    want=$(want_sha "$f")
    mkdir -p "$SRC"
    if [ ! -s "$SRC/$f" ]; then find_local "$f" "$want" || true; fi
    if [ ! -s "$SRC/$f" ]; then
        curl_bin=$(pick_curl) || die "Không có lệnh curl."
        urls=$(url_for "$f") || die "Không biết URL của $f"
        while read -r u; do
            [ -n "$u" ] || continue
            log "  - tải $f  ($u)"
            rm -f "$SRC/$f.part"
            # -4: ép IPv4 (nhiều VPS CentOS 7 không có IPv6). CURL_OPTS đứng sau nên có thể ghi đè (vd -6, -x proxy)
            # shellcheck disable=SC2086
            if "$curl_bin" -4 -fsSL --retry 1 --connect-timeout 15 --max-time 900 $CURL_OPTS -o "$SRC/$f.part" "$u"; then
                got=$(sha_of "$SRC/$f.part")
                # kiểm sha256 ngay trên file vừa tải: trang lỗi/captive portal sẽ bị loại và thử nguồn kế tiếp
                if [ -z "$want" ] || [ "$got" = "$want" ]; then ok=1; break; fi
                warn "sha256 không khớp từ $u (nhận ${got:0:12}..., cần ${want:0:12}...), thử nguồn khác"
            fi
            rm -f "$SRC/$f.part"
        done <<<"$urls"
        if [ "$ok" != 1 ]; then
            first=$(PHP_MIRRORS="" url_for "$f" | sed -n '1p')
            die "Không tải được $f.
    Kiểm tra mạng của máy này:  curl -4 -sI -m 10 https://www.php.net | head -1
    Cách 1 - tải ở máy khác rồi chép vào $SRC/ :
               curl -LO $first
               scp $f root@$(hostname -f 2>/dev/null || hostname):$SRC/
             (hoặc chạy '$0 fetch' trên máy khác với SRC=./src rồi scp cả thư mục)
    Cách 2 - dùng proxy:   CURL_OPTS='-x http://host:port' $0 ...
    Cách 3 - dùng mirror:  PHP_MIRRORS='https://mirror/php' $0 ...
             (hoặc đặt SRC=.../payload/additions của bộ git cũ)"
        fi
        mv "$SRC/$f.part" "$SRC/$f"
    fi
    if [ -n "$want" ]; then
        [ "$(sha_of "$SRC/$f")" = "$want" ] || die "Sai sha256: $SRC/$f (xóa file rồi chạy lại)"
    else
        warn "Không có sha256 tham chiếu cho $f"
    fi
}

# ./da-php-build.sh fetch [deps|all|8.x ...]   (không tham số = all)
fetch_cmd() {
    local a v f
    local -a args=("$@") files=()
    [ "${#args[@]}" -gt 0 ] || args=(all)
    for a in "${args[@]}"; do
        case "$a" in
            deps) for f in $DEP_FILES; do files+=("$f"); done ;;
            all)  for f in $DEP_FILES; do files+=("$f"); done
                  for v in $BRANCHES; do files+=("php-${PHPV[$v]}.tar.gz"); done ;;
            *)    [ -n "${PHPV[$a]:-}" ] || die "Không hỗ trợ '$a' (dùng: deps, all, $BRANCHES)"
                  files+=("php-${PHPV[$a]}.tar.gz") ;;
        esac
    done
    for f in "${files[@]}"; do fetch "$f"; done
    log "Source đã đủ và đã kiểm sha256 trong $SRC"
}

fetch_extract() {  # file thư-mục-đích
    fetch "$1"
    rm -rf "${WORK:?}/$2"; mkdir -p "$WORK/$2"
    run "giải nén $1" tar -xf "$SRC/$1" -C "$WORK/$2" --strip-components=1
}

# ---------------------------------------------------------------- dependency (vào $DEPS)
dep_env() {
    export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:/usr/local/lib/pkgconfig"
    export CPPFLAGS="-I$DEPS/include"
    export LDFLAGS="-L$DEPS/lib -Wl,-rpath,$DEPS/lib -Wl,--disable-new-dtags"
    export CFLAGS="-O2 -fPIC"
    export CXXFLAGS="-O2 -fPIC"
}
stamp() { [ -f "$DEPS/.stamp-$1" ]; }
mark()  { touch "$DEPS/.stamp-$1"; }

autotools_dep() {  # tên file-source cờ-configure...
    local n=$1 f=$2; shift 2
    stamp "$n" && return 0
    CUR=$n; log "Build $n"
    fetch_extract "$f" "$n"; cd "$WORK/$n"
    run configure ./configure --prefix="$DEPS" --libdir="$DEPS/lib" "$@"
    run make make -j"$JOBS"
    run install make install
    mark "$n"
}

dep_openssl() {
    local n=openssl-1.1.1w
    stamp $n && return 0
    CUR=$n; log "Build $n"
    fetch_extract $n.tar.gz $n; cd "$WORK/$n"
    run config ./config --prefix="$DEPS" --openssldir="$DEPS/ssl" --libdir=lib shared zlib-dynamic
    run make make -j"$JOBS"
    run install make install_sw install_ssldirs
    # dùng CA bundle của hệ thống (không có thì curl/openssl_* sẽ không verify được HTTPS)
    if [ -r /etc/pki/tls/certs/ca-bundle.crt ]; then
        rm -rf "$DEPS/ssl/certs" "$DEPS/ssl/cert.pem"
        ln -s /etc/pki/tls/certs "$DEPS/ssl/certs"
        ln -s /etc/pki/tls/certs/ca-bundle.crt "$DEPS/ssl/cert.pem"
    fi
    mark $n
}

dep_icu() {
    local n=icu-57.1
    stamp $n && return 0
    CUR=$n; log "Build $n"
    fetch_extract icu4c-57_1-src.tgz $n; cd "$WORK/$n/source"
    run configure env CXXFLAGS="-O2 -fPIC -std=gnu++11" ./configure --prefix="$DEPS" --libdir="$DEPS/lib" \
        --enable-shared --disable-static --disable-samples --disable-tests
    run make make -j"$JOBS"
    run install make install
    mark $n
}

deps() {
    dep_env; toolchain
    mkdir -p "$DEPS"
    # ICU lâu nhất nên chạy song song với phần còn lại
    local icu_pid=
    if ! stamp icu-57.1; then
        ( CUR=icu-57.1; dep_icu ) & icu_pid=$!
    fi
    autotools_dep zlib-1.3.1 zlib-1.3.1.tar.gz
    dep_openssl
    autotools_dep gmp-6.2.1 gmp-6.2.1.tar.xz --enable-shared --disable-static --enable-fat
    autotools_dep libxml2-2.9.14 libxml2-2.9.14.tar.xz --without-python --without-lzma --with-zlib="$DEPS" --disable-static
    autotools_dep curl-7.88.1 curl-7.88.1.tar.xz --with-openssl="$DEPS" --with-zlib="$DEPS" \
        --with-ca-bundle=/etc/pki/tls/certs/ca-bundle.crt --without-libidn2 --without-nghttp2 \
        --without-libpsl --without-brotli --without-zstd --disable-ldap --disable-ldaps --disable-static
    autotools_dep onig-6.9.9 onig-6.9.9.tar.gz --disable-static
    autotools_dep libzip-1.2.0 libzip-1.2.0.tar.gz --disable-static
    autotools_dep sqlite-3.45.3 sqlite-autoconf-3450300.tar.gz --enable-shared --disable-static
    if [ -n "$icu_pid" ]; then
        log "Đợi ICU 57.1 (build nền) ..."
        wait "$icu_pid" || die "ICU 57.1 lỗi, xem $LOGS/icu-57.1.log"
    fi
    log "Dependency xong tại $DEPS"
}

# ---------------------------------------------------------------- PHP
# GCC 4.8 (CentOS 7) quá cũ cho PHP 8.4/8.5: áp 2 bản vá nhỏ (lấy từ bộ git cũ).
# Nếu dùng TOOLCHAIN=scl (GCC >= 5) thì không cần.
apply_php_patches() {
    local v=$1 pf="$WORK/gcc48-$1.patch"
    [ "$GCC_MAJOR" -lt 5 ] || return 0
    case "$v" in
        8.4) cat >"$pf" <<'PATCH_EOF'
--- a/ext/hash/php_hash_sha.h
+++ b/ext/hash/php_hash_sha.h
@@ -58,7 +58,7 @@
 #if ((defined(__i386__) || defined(__x86_64__)) && defined(HAVE_IMMINTRIN_H)) || defined(_M_X64) || defined(_M_IX86)
 # if defined(__SSSE3__) && defined(__SHA__)
 #  define PHP_HASH_INTRIN_SHA_NATIVE 1
-# elif defined(HAVE_FUNC_ATTRIBUTE_TARGET) || defined(_M_X64) || defined(_M_IX86)
+# elif (defined(HAVE_FUNC_ATTRIBUTE_TARGET) && (!defined(__GNUC__) || __GNUC__ >= 5)) || defined(_M_X64) || defined(_M_IX86)
 #  define PHP_HASH_INTRIN_SHA_RESOLVER 1
 # endif
 #endif
--- a/Zend/zend_portability.h
+++ b/Zend/zend_portability.h
@@ -795,7 +795,7 @@
 
 #if (defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L) /* C11 */
 typedef max_align_t zend_max_align_t;
-#elif (defined(__cplusplus) && __cplusplus >= 201103L) /* C++11 */
+#elif (defined(__cplusplus) && __cplusplus >= 201103L && (!defined(__GNUC__) || __GNUC__ >= 5)) /* C++11 */
 extern "C++" {
 # include <cstddef>
 }
PATCH_EOF
        ;;
        8.5) cat >"$pf" <<'PATCH_EOF'
--- a/ext/hash/php_hash_sha.h
+++ b/ext/hash/php_hash_sha.h
@@ -58,7 +58,7 @@
 #if ((defined(__i386__) || defined(__x86_64__)) && defined(HAVE_IMMINTRIN_H)) || defined(_M_X64) || defined(_M_IX86)
 # if defined(__SSSE3__) && defined(__SHA__)
 #  define PHP_HASH_INTRIN_SHA_NATIVE 1
-# elif defined(HAVE_FUNC_ATTRIBUTE_TARGET) || defined(_M_X64) || defined(_M_IX86)
+# elif (defined(HAVE_FUNC_ATTRIBUTE_TARGET) && (!defined(__GNUC__) || __GNUC__ >= 5)) || defined(_M_X64) || defined(_M_IX86)
 #  define PHP_HASH_INTRIN_SHA_RESOLVER 1
 # endif
 #endif
--- a/Zend/zend_portability.h
+++ b/Zend/zend_portability.h
@@ -835,7 +835,7 @@
 #endif
 
 #if ((defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L) /* C11 */ \
-  || (defined(__cplusplus) && __cplusplus >= 201103L) /* C++11 */) && !defined(ZEND_WIN32)
+  || (defined(__cplusplus) && __cplusplus >= 201103L && (!defined(__GNUC__) || __GNUC__ >= 5)) /* C++11 */) && !defined(ZEND_WIN32)
 typedef max_align_t zend_max_align_t;
 #else
 typedef union {
PATCH_EOF
        ;;
        *) return 0 ;;
    esac
    run "vá GCC 4.8 cho PHP $v" patch -p1 -i "$pf"
}

write_fpm_conf() {  # prefix suffix
    local P=$1 s=$2
    mkdir -p "$P/etc" "$P/sockets" "$P/var/log" "$P/var/run" "$P/lib/php.conf.d"
    chown root:root "$P/sockets"; chmod 0755 "$P/sockets"
    cat >"$P/etc/php-fpm.conf" <<EOF
[global]
error_log = log/php-fpm.log
log_level = notice

;;;;;;;;;;;;;;;;;;;;
; Pool Definitions ;
;;;;;;;;;;;;;;;;;;;;

[webapps]
user = \$pool
group = \$pool

listen = $P/sockets/\$pool.sock
listen.owner = \$pool
listen.group = $WEB_GROUP
listen.mode = 660

pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 60
pm.max_requests = 1000

security.limit_extensions = .php .php5 .php$s .inc .phtml

; Load all DA User configs
include=/usr/local/directadmin/data/users/*/php/php-fpm$s.conf
EOF
}

write_unit() {  # suffix
    local s=$1 P=/usr/local/php$1
    cat >"/etc/systemd/system/php-fpm$s.service" <<EOF
# php-fpm$s - build bởi da-php-build.sh (layout giống DirectAdmin CustomBuild)
[Unit]
Description=The PHP ${s:0:1}.${s:1} FastCGI Process Manager
After=syslog.target network.target

[Service]
Type=notify
PIDFile=/run/php-fpm$s.pid
ExecStart=$P/sbin/php-fpm$s --nodaemonize --pid=/run/php-fpm$s.pid
ExecReload=/bin/kill -USR2 \$MAINPID
LimitMEMLOCK=infinity
LimitNOFILE=65535
PrivateTmp=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=false
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

verify_php() {  # branch prefix suffix
    local v=$1 P=$2 s=$3 php="$2/bin/php$3" m bad=0
    local -a bins=("$php")
    if [ -x "$P/sbin/php-fpm$s" ]; then bins+=("$P/sbin/php-fpm$s"); fi
    if [ -x "$P/bin/lsphp$s" ];    then bins+=("$P/bin/lsphp$s"); fi
    log "Kiểm tra PHP $v"
    "$php" -v 2>&1 | sed -n '1,2p'
    for m in intl openssl curl mbstring gd zip sqlite3 pdo_sqlite gmp dom xsl mysqli pdo_mysql bcmath sockets soap "Zend OPcache"; do
        "$php" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$m" || { warn "Thiếu module: $m"; bad=1; }
    done
    log "  ICU: $("$php" -r 'echo INTL_ICU_VERSION;' 2>/dev/null)  OpenSSL: $("$php" -r 'echo OPENSSL_VERSION_TEXT;' 2>/dev/null)"
    if ldd "${bins[@]}" 2>&1 | grep -q 'not found'; then
        ldd "${bins[@]}" 2>&1 | grep 'not found' >&2
        die "Thiếu thư viện runtime (xem ở trên)"
    fi
    if ! ldd "$php" | grep -q "libssl.so.1.1 => $DEPS/"; then
        warn "php$s không link OpenSSL 1.1.1 trong $DEPS (kiểm tra ldd)"; bad=1
    fi
    if [ -x "$P/sbin/php-fpm$s" ] && ! "$P/sbin/php-fpm$s" -t >/dev/null 2>&1; then
        warn "php-fpm$s -t chưa đạt (bình thường nếu máy này chưa có user 'webapps'/group '$WEB_GROUP' của DirectAdmin)"
    fi
    if [ -x "$P/bin/lsphp$s" ]; then
        log "  lsphp: $("$P/bin/lsphp$s" -v 2>&1 | sed -n '1p')"
    fi
    if [ "$bad" = 0 ]; then log "PHP $v: OK"; else warn "PHP $v: build xong nhưng có cảnh báo ở trên"; fi
}

# Lấy binary lsphp từ cây source (chạy trong thư mục source, sau make install).
# Không phụ thuộc việc 'make install' đặt tên là lsphp hay lsphpXX; xóa bản cũ trước khi chép
# để tránh "Text file busy" khi OLS đang chạy lsphp cũ.
install_lsphp() {  # prefix suffix
    local P=$1 s=$2 c b=""
    for c in sapi/litespeed/php sapi/litespeed/lsphp; do
        if [ -x "$c" ]; then b=$c; break; fi
    done
    [ -n "$b" ] || die "Không thấy binary lsphp trong sapi/litespeed/ (configure có --enable-litespeed không?)"
    rm -f "$P/bin/lsphp" "$P/bin/lsphp$s"
    install -m 0755 "$b" "$P/bin/lsphp$s"
    ln -sfn "lsphp$s" "$P/bin/lsphp"
}

build_php() {
    local v=$1 full s P f svc was_active=0 fpm=0 lsp=0
    [ -n "${PHPV[$v]:-}" ] || die "Không hỗ trợ PHP '$v' (chỉ: $BRANCHES)"
    full=${PHPV[$v]}; s=${v/./}; P=/usr/local/php$s; f=php-$full.tar.gz; svc=php-fpm$s
    case "$BUILD_MODE" in
        fpm)   fpm=1 ;;
        lsphp) lsp=1 ;;
        both)  fpm=1; lsp=1 ;;
        *)     die "BUILD_MODE chưa được xác định (gọi resolve_mode trước)" ;;
    esac
    CUR=php-$full
    if [ -e "$P/bin/php$s" ] && [ ! -f "$P/.dabuild-managed" ] && [ "$FORCE" != 1 ]; then
        die "$P đã có PHP không do script này tạo (CustomBuild?). Dùng FORCE=1 nếu chắc chắn muốn ghi đè."
    fi
    log "===== Build PHP $full [$BUILD_MODE] -> $P ====="
    dep_env; toolchain
    fetch_extract "$f" "php-$full"; cd "$WORK/php-$full"
    apply_php_patches "$v"

    local -a cfg=(
        --prefix="$P" --program-suffix="$s"
        --with-config-file-scan-dir="$P/lib/php.conf.d"
        --with-curl="$DEPS" --with-openssl="$DEPS" --with-zlib --with-zip
        --with-gmp="$DEPS" --with-sqlite3 --with-pdo-sqlite
        --enable-gd --with-jpeg --with-freetype --with-webp
        --with-gettext --with-mhash --with-xsl --with-pear
        --with-mysql-sock=/var/lib/mysql/mysql.sock --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
        --enable-bcmath --enable-calendar --enable-exif --enable-ftp --enable-sockets
        --enable-soap --enable-mbstring --enable-intl
    )
    if [ "$fpm" = 1 ]; then cfg+=(--enable-fpm --with-fpm-systemd); fi
    if [ "$lsp" = 1 ]; then cfg+=(--enable-litespeed); fi
    [ "$v" = 8.5 ] || cfg+=(--enable-opcache)    # PHP 8.5: OPcache luôn được build sẵn
    if pkg-config --exists libsodium 2>/dev/null; then cfg+=(--with-sodium)
    elif [ -f /usr/local/include/sodium.h ]; then cfg+=(--with-sodium=/usr/local)
    else warn "Không thấy libsodium-devel -> bỏ ext sodium"; fi
    if [ -n "$EXTRA_CONFIGURE" ]; then
        local -a extra; read -r -a extra <<<"$EXTRA_CONFIGURE"; cfg+=("${extra[@]}")
    fi

    run "configure PHP $v" ./configure "${cfg[@]}"
    run "make PHP $v (-j$JOBS)" make -j"$JOBS"

    # dừng service ngay trước khi thay binary để downtime tối thiểu (chỉ áp dụng cho FPM)
    if [ "$fpm" = 1 ] && systemctl is-active --quiet "$svc" 2>/dev/null; then
        was_active=1; log "Dừng $svc để thay binary"; systemctl stop "$svc"
    fi
    run "make install" make install
    mkdir -p "$P/lib/php.conf.d"
    if [ "$fpm" = 1 ]; then write_fpm_conf "$P" "$s"; fi
    install -m 0644 php.ini-production "$P/lib/php.ini"
    sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$P/lib/php.ini"
    if [ "$v" != 8.5 ]; then
        printf 'zend_extension=opcache\nopcache.enable=1\nopcache.memory_consumption=128\n' >"$P/lib/php.conf.d/10-opcache.ini"
    else
        printf 'opcache.enable=1\nopcache.memory_consumption=128\n' >"$P/lib/php.conf.d/10-opcache.ini"
    fi
    ln -sfn "php$s" "$P/bin/php"
    ln -sfn "phpize$s" "$P/bin/phpize"
    ln -sfn "php-config$s" "$P/bin/php-config"
    if [ "$fpm" = 1 ]; then ln -sfn "php-fpm$s" "$P/sbin/php-fpm"; fi
    if [ "$lsp" = 1 ]; then install_lsphp "$P" "$s"; fi
    printf '%s\n' "$full $(date +%F) mode=$BUILD_MODE" >"$P/.dabuild-managed"
    if [ "$fpm" = 1 ]; then
        write_unit "$s"
        systemctl daemon-reload
        systemctl enable "$svc" >/dev/null 2>&1 || true
    fi
    verify_php "$v" "$P" "$s"

    if [ "$fpm" = 1 ]; then
        if [ "$was_active" = 1 ] || [ "$RESTART" = 1 ]; then
            systemctl restart "$svc" && log "Đã restart $svc" || warn "Restart $svc lỗi: journalctl -u $svc"
        else
            log "Chưa start service. Khi sẵn sàng: systemctl start $svc"
        fi
    fi
    if [ "$lsp" = 1 ]; then
        log "lsphp: $P/bin/lsphp$s (OLS tự khởi chạy, không có service)"
        if [ "$RESTART" = 1 ]; then
            pkill -f "$P/bin/lsphp" 2>/dev/null || true
            log "Đã kill lsphp$s cũ; OLS sẽ khởi chạy lại bản mới khi có request"
        else
            log "Nếu OLS đang chạy lsphp$s cũ: systemctl restart lsws (hoặc chạy lại với RESTART=1)"
        fi
        log "Lưu ý: cấu hình OLS do 'build rewrite_confs' của DirectAdmin sinh ra; script này không sửa nó."
    fi
    log "===== PHP $full xong ====="
}

# ---------------------------------------------------------------- đóng gói / triển khai
pack() {
    [ "$(id -u)" = 0 ] || die "Cần chạy bằng root."
    mkdir -p "$OUT"
    local -a list=("${DEPS#/}") v s
    for v in $BRANCHES; do
        s=${v/./}
        if [ -f "/usr/local/php$s/.dabuild-managed" ]; then
            list+=("usr/local/php$s")
            if [ -f "/etc/systemd/system/php-fpm$s.service" ]; then list+=("etc/systemd/system/php-fpm$s.service"); fi
        fi
    done
    [ "${#list[@]}" -gt 1 ] || die "Chưa có bản PHP nào do script build."
    local file="$OUT/da-php-$(date +%Y%m%d-%H%M).tar.gz"
    run "nén ${list[*]}" tar -czf "$file" -C / "${list[@]}"
    (cd "$OUT" && sha256sum "$(basename "$file")" >"$(basename "$file").sha256")
    log "Đã tạo: $file"
    log "Trên server đích: $0 unpack $file"
}

unpack() {
    local file=${1:-}
    [ -f "$file" ] || die "Dùng: $0 unpack FILE.tar.gz"
    [ "$(id -u)" = 0 ] || die "Cần chạy bằng root."
    [ ! -f "$file.sha256" ] || (cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256" >/dev/null) || die "Sai checksum tar"
    local p s active=""
    local prefixes
    prefixes=$(tar -tzf "$file" | awk -F/ '$1 == "usr" && $2 == "local" && $3 ~ /^php[0-9]+$/ {print $3}' | sort -u)
    for p in $prefixes; do
        if [ -e "/usr/local/$p" ] && [ ! -f "/usr/local/$p/.dabuild-managed" ] && [ "$FORCE" != 1 ]; then
            die "/usr/local/$p đã tồn tại và không do script này tạo. Dùng FORCE=1 để ghi đè."
        fi
    done
    for p in $prefixes; do
        s=${p#php}
        if systemctl is-active --quiet "php-fpm$s" 2>/dev/null; then active="$active $s"; systemctl stop "php-fpm$s"; fi
    done
    tar -xzf "$file" -C /
    systemctl daemon-reload
    for p in $prefixes; do s=${p#php}; systemctl enable "php-fpm$s" >/dev/null 2>&1 || true; done
    for s in $active; do systemctl start "php-fpm$s" || warn "Start php-fpm$s lỗi"; done
    log "Đã giải nén: $prefixes"
    log "Cần có thư viện runtime: yum install -y libpng libjpeg-turbo freetype libwebp libxslt bzip2-libs (và libsodium nếu build có sodium)"
    log "Start: systemctl start php-fpm<ver>   (vd: systemctl start php-fpm84)"
    log "Bản build lsphp (nếu có): không cần service, trỏ OLS tới /usr/local/phpXX/bin/lsphpXX rồi systemctl restart lsws"
}

usage() { awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; }

main() {
    local cmd=${1:-help}; shift || true
    case "$cmd" in
        check)  preflight; toolchain; resolve_mode ;;
        detect) resolve_mode ;;
        fetch)  fetch_cmd "$@" ;;
        setup)  setup_pkgs ;;
        deps)   preflight; deps ;;
        php)
            [ "$#" -gt 0 ] || die "Dùng: $0 php 8.4 | php 8.2 8.3 8.4 8.5 | php all"
            [ "$1" != all ] || set -- $BRANCHES
            preflight; resolve_mode; deps
            local v; for v in "$@"; do build_php "$v"; done
            log "Hoàn tất. Đóng gói để mang sang server khác: $0 pack" ;;
        pack)   pack ;;
        unpack) unpack "$@" ;;
        *)      usage ;;
    esac
}
main "$@"
