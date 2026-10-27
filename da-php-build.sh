#!/usr/bin/env bash
#
# da-php-build.sh - Build PHP 8.2 / 8.3 / 8.4 / 8.5 từ source trên CentOS 7 (DirectAdmin cũ)
#
# Ý tưởng: build dependency MỘT LẦN vào /opt/dabuild (OpenSSL 1.1.1, ICU 57, libxml2,
# curl, ...), sau đó build từng bản PHP vào /usr/local/phpXX theo đúng layout của
# DirectAdmin/CustomBuild. Runtime được build độc lập; lệnh integrate riêng mới đăng ký
# một bản PHP vào slot phụ và chạy rewrite_confs. Không tự đổi PHP chính.
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
#   ./da-php-build.sh extensions 8.4           # build Redis + Imagick cho PHP 8.4
#   ./da-php-build.sh extensions all           # build Redis + Imagick cho mọi runtime
#   ./da-php-build.sh integrate 8.5 4 USER DOMAIN [USER DOMAIN ...]
#                                             # backport metadata PHP mới vào CustomBuild cũ,
#                                             # đăng ký slot phụ, chọn một/nhiều domain,
#                                             # rewrite một lần rồi kiểm tra pool/socket/vhost
#   ./da-php-build.sh recover /var/tmp/dabuild/transactions/.../run.XXXXXX
#                                             # rollback transaction dở dang sau crash/SIGKILL
#   ./da-php-build.sh pack                    # đóng tar để mang sang server khác
#   ./da-php-build.sh unpack FILE.tar.gz      # fail-closed: đang khóa cho tới khi có staged transactional extractor
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
# Lưu ý DirectAdmin 1.62.x chỉ có 4 slot. Script không ghi đè slot đang dùng nếu chưa đặt
# FORCE_SLOT=1; hãy kiểm tra các domain đang dùng slot đó trước khi thay đổi.
#
# Nên chạy trong screen/tmux; log nội bộ mặc định nằm trong $LOGS.

set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

DEPS=${DEPS:-/opt/dabuild}
SRC=${SRC:-/usr/local/src/dabuild}
PROJECT_HOME=${PROJECT_HOME:-/srv/dtq-projects/directadmin-legacy-php-builder}
WORK=${WORK:-$PROJECT_HOME/work/runtime}
LOGS=${LOGS:-$PROJECT_HOME/logs/build/$(date +%Y-%m)}
OUT=${OUT:-$PROJECT_HOME/artifacts/releases}
BACKUP_ROOT=${BACKUP_ROOT:-$PROJECT_HOME/backups}
TOOLCHAIN=${TOOLCHAIN:-system}
EXTRA_CONFIGURE=${EXTRA_CONFIGURE:-}
FORCE=${FORCE:-0}
RESTART=${RESTART:-0}
MODE=${MODE:-auto}
WEB_GROUP=${WEB_GROUP:-}
DA_OPTIONS=${DA_OPTIONS:-/usr/local/directadmin/custombuild/options.conf}
CURL_OPTS=${CURL_OPTS:-}
PHP_MIRRORS=${PHP_MIRRORS:-}
REDIS_VERSION=${REDIS_VERSION:-6.3.0}
IMAGICK_VERSION=${IMAGICK_VERSION:-3.8.1}
INSTALL_EXTENSIONS=${INSTALL_EXTENSIONS:-1}
FORCE_SLOT=${FORCE_SLOT:-0}
DA_CB=${DA_CB:-/usr/local/directadmin/custombuild}
PHP_PREFIX_ROOT=${PHP_PREFIX_ROOT:-/usr/local}
DEP_FILES="zlib-1.3.1.tar.gz openssl-1.1.1w.tar.gz gmp-6.2.1.tar.xz libxml2-2.9.14.tar.xz curl-7.88.1.tar.xz onig-6.9.9.tar.gz libzip-1.2.0.tar.gz sqlite-autoconf-3450300.tar.gz icu4c-57_1-src.tgz"
EXT_FILES="redis-${REDIS_VERSION}.tgz imagick-${IMAGICK_VERSION}.tgz"

declare -A PHPV=([8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12)
declare -A PHPMD5=([8.2]=3fa83f5597c09bd91d2902789771e06e [8.3]=c9129e4f1b240a9dc3b4eb5217a14dfa [8.4]=c8109ea159be68efe2af1036faed0d39 [8.5]=5c8ef077556bb36a81e72510410676fc)
BRANCHES="8.2 8.3 8.4 8.5"

TOOL_PKGS="gcc gcc-c++ make perl patch tar xz curl pkgconfig ca-certificates autoconf automake libtool"
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
SUMS+=$'\n0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5  additions/redis-6.3.0.tgz'
SUMS+=$'\n3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee  additions/imagick-3.8.1.tgz'

T0=$SECONDS
ts()   { printf '%02d:%02d' $(((SECONDS - T0) / 60)) $(((SECONDS - T0) % 60)); }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] CẢNH BÁO: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] LỖI: %s\n' "$(ts)" "$*" >&2; exit 1; }
STOPPED_SERVICE=""
INTEGRATION_ACTIVE=0
INTEGRATION_SCOPE_LIST=""
INTEGRATION_TX_DIR=""
INTEGRATION_PRE_REWRITE_LIST=""
INTEGRATION_SERVICE_STATES=""
INTEGRATION_LOCK_FD=""
RUNTIME_ACTIVE=0
RUNTIME_TX_DIR=""
RUNTIME_PREFIX=""
RUNTIME_SERVICE=""
RUNTIME_UNIT=""
EXTENSION_ACTIVE=0
EXTENSION_SCOPE_LIST=""
EXTENSION_TX_DIR=""
EXTENSION_BRANCH=""
cleanup_on_exit() {
    local rc=$? cleanup_failed=0
    trap - ERR EXIT
    set +e
    if [ "$EXTENSION_ACTIVE" = 1 ] && declare -F rollback_extension >/dev/null 2>&1; then
        rollback_extension || cleanup_failed=1
    fi
    if [ "$RUNTIME_ACTIVE" = 1 ] && declare -F rollback_runtime >/dev/null 2>&1; then
        rollback_runtime || cleanup_failed=1
    fi
    if [ "$INTEGRATION_ACTIVE" = 1 ] && declare -F rollback_integration >/dev/null 2>&1; then
        rollback_integration || cleanup_failed=1
    fi
    if [ -n "$STOPPED_SERVICE" ] && ! systemctl is-active --quiet "$STOPPED_SERVICE" 2>/dev/null; then
        if ! systemctl start "$STOPPED_SERVICE" >/dev/null 2>&1; then
            warn "Không khôi phục được service $STOPPED_SERVICE"
            cleanup_failed=1
        fi
    fi
    if [ "$cleanup_failed" = 1 ]; then
        warn "Rollback/khôi phục service chưa hoàn tất; cần kiểm tra thủ công."
        [ "$rc" -ne 0 ] || rc=1
    fi
    exit "$rc"
}
trap cleanup_on_exit EXIT
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
    for c in gcc g++ make perl patch tar xz curl pkg-config sha256sum autoconf automake libtool; do
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
    local free_gb probe=$WORK
    while [ ! -e "$probe" ] && [ "$probe" != / ]; do probe=$(dirname "$probe"); done
    free_gb=$(df -Pk "$probe" | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')
    [ "$free_gb" -ge 8 ] || die "Cần tối thiểu ~8GB trống tại $WORK (đang có ${free_gb}GB)."
    log "Máy OK: $JOBS luồng make, ${free_gb}GB trống, SRC=$SRC"
}

secure_root_dir() {  # absolute directory; create one component at a time
    local path=$1 current=/ part uid mode
    local -a parts=()
    [[ "$path" = /* ]] || die "Đường dẫn transaction phải tuyệt đối: $path"
    IFS='/' read -r -a parts <<<"${path#/}"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        current=${current%/}/$part
        if [ -e "$current" ] || [ -L "$current" ]; then
            [ -d "$current" ] && [ ! -L "$current" ] \
                || die "Transaction path không phải thư mục thật: $current"
        else
            (umask 077; mkdir "$current") || die "Không tạo được transaction directory an toàn: $current"
        fi
        uid=$(stat -Lc '%u' "$current")
        mode=$(stat -Lc '%a' "$current")
        [ "$uid" -eq 0 ] || die "Transaction path không thuộc root: $current"
        (( (8#$mode & 0022) == 0 )) \
            || die "Transaction path cho phép group/other ghi: $current ($mode)"
    done
}

prepare_dirs() {
    secure_root_dir "$WORK"
    mkdir -p "$LOGS" "$SRC" "$OUT" "$BACKUP_ROOT"
}

quarantine_existing() {  # path [reason]
    local path=$1 reason=${2:-replaced} rel q
    [ -e "$path" ] || [ -L "$path" ] || return 0
    rel=${path#/}
    q="$WORK/quarantine/$reason-$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}/$rel"
    mkdir -p "$(dirname "$q")"
    mv "$path" "$q"
    log "Đã chuyển bản cũ vào quarantine: $q"
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
        redis-*)    echo "https://pecl.php.net/get/$1" ;;
        imagick-*)  echo "https://pecl.php.net/get/$1" ;;
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
    local f=$1 u urls want got first curl_bin part ok=0
    want=$(want_sha "$f")
    mkdir -p "$SRC"
    if [ ! -s "$SRC/$f" ]; then find_local "$f" "$want" || true; fi
    if [ ! -s "$SRC/$f" ]; then
        curl_bin=$(pick_curl) || die "Không có lệnh curl."
        urls=$(url_for "$f") || die "Không biết URL của $f"
        while read -r u; do
            [ -n "$u" ] || continue
            log "  - tải $f  ($u)"
            part="$SRC/$f.part.$$.$RANDOM"
            # -4: ép IPv4 (nhiều VPS CentOS 7 không có IPv6). CURL_OPTS đứng sau nên có thể ghi đè (vd -6, -x proxy)
            # shellcheck disable=SC2086
            if "$curl_bin" -4 -fsSL --retry 1 --connect-timeout 15 --max-time 900 $CURL_OPTS -o "$part" "$u"; then
                got=$(sha_of "$part")
                # kiểm sha256 ngay trên file vừa tải: trang lỗi/captive portal sẽ bị loại và thử nguồn kế tiếp
                if [ -z "$want" ] || [ "$got" = "$want" ]; then ok=1; break; fi
                warn "sha256 không khớp từ $u (nhận ${got:0:12}..., cần ${want:0:12}...), thử nguồn khác"
            fi
            quarantine_existing "$part" failed-download
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
        mv "$part" "$SRC/$f"
    fi
    if [ -n "$want" ]; then
        [ "$(sha_of "$SRC/$f")" = "$want" ] || die "Sai sha256: $SRC/$f (chuyển file sai vào quarantine rồi chạy lại)"
    else
        warn "Không có sha256 tham chiếu cho $f"
    fi
}

# ./da-php-build.sh fetch [deps|extensions|all|8.x ...]   (không tham số = all)
fetch_cmd() {
    local a v f
    local -a args=("$@") files=()
    [ "${#args[@]}" -gt 0 ] || args=(all)
    for a in "${args[@]}"; do
        case "$a" in
            deps) for f in $DEP_FILES; do files+=("$f"); done ;;
            extensions) for f in $EXT_FILES; do files+=("$f"); done ;;
            all)  for f in $DEP_FILES; do files+=("$f"); done
                  for f in $EXT_FILES; do files+=("$f"); done
                  for v in $BRANCHES; do files+=("php-${PHPV[$v]}.tar.gz"); done ;;
            *)    [ -n "${PHPV[$a]:-}" ] || die "Không hỗ trợ '$a' (dùng: deps, extensions, all, $BRANCHES)"
                  files+=("php-${PHPV[$a]}.tar.gz") ;;
        esac
    done
    for f in "${files[@]}"; do fetch "$f"; done
    log "Source đã đủ và đã kiểm sha256 trong $SRC"
}

fetch_extract() {  # file thư-mục-đích
    fetch "$1"
    quarantine_existing "${WORK:?}/$2" reextract
    mkdir -p "$WORK/$2"
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
        quarantine_existing "$DEPS/ssl/certs" ca-link-refresh
        quarantine_existing "$DEPS/ssl/cert.pem" ca-link-refresh
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

# ---------------------------------------------------------------- extension PHP
backup_once() {  # đường dẫn tuyệt đối
    local src=$1 day base manifest rel dst hash src_hash dst_hash
    [ "${src#/}" != "$src" ] || die "Backup chỉ nhận đường dẫn tuyệt đối: $src"
    day=$(date +%F)
    base="$BACKUP_ROOT/$day/baseline"
    manifest="$BACKUP_ROOT/$day/manifest.sha256"
    rel=${src#/}
    dst="$base/$rel"
    mkdir -p "$base" "$(dirname "$dst")"
    touch "$manifest" "$BACKUP_ROOT/$day/changes.log"
    if awk -v rel="$rel" '
        # sha256sum format is: 64 hex bytes, two marker bytes, then the
        # pathname verbatim. Never split on whitespace: valid paths may contain it.
        length($0) >= 66 && substr($0, 65, 2) == "  " && substr($0, 67) == rel {found=1}
        END {exit !found}
    ' "$manifest" || grep -Fxq $'# ABSENT\t'"$src" "$manifest"; then
        return 0
    fi
    if [ -e "$src" ] || [ -L "$src" ]; then
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            if [ -L "$src" ] && [ -L "$dst" ]; then
                src_hash=$(readlink -n -- "$src" | sha256sum | cut -d' ' -f1) \
                    || die "Không đọc được symlink baseline: $src"
                dst_hash=$(readlink -n -- "$dst" | sha256sum | cut -d' ' -f1) \
                    || die "Không đọc được symlink baseline: $dst"
                [ "$src_hash" = "$dst_hash" ] \
                    || die "Baseline cùng ngày đã tồn tại nhưng khác symlink gốc: $dst"
            elif [ -f "$src" ] && [ -f "$dst" ] && [ ! -L "$src" ] && [ ! -L "$dst" ]; then
                cmp -s "$src" "$dst" \
                    || die "Baseline cùng ngày đã tồn tại nhưng khác file gốc: $dst"
            else
                die "Baseline cùng ngày đã tồn tại nhưng khác loại đối tượng: $dst"
            fi
        else
            cp -a "$src" "$dst"
        fi
        if [ -L "$src" ]; then
            hash=$(readlink -n -- "$src" | sha256sum | cut -d' ' -f1) \
                || die "Không checksum được symlink: $src"
            printf '%s  %s\n' "$hash" "$rel" >>"$manifest"
        elif [ -f "$src" ]; then
            (cd "$base" && sha256sum -- "$rel") >>"$manifest"
        else
            die "Backup baseline chỉ hỗ trợ file hoặc symlink: $src"
        fi
    else
        printf '# ABSENT\t%s\n' "$src" >>"$manifest"
    fi
}

record_change() {
    local scope=$1; shift
    mkdir -p "$BACKUP_ROOT/$(date +%F)"
    printf '%s\tscope=%s\t%s\n' "$(date '+%F %T %Z')" "$scope" "$*" >>"$BACKUP_ROOT/$(date +%F)/changes.log"
}

# Flush data, metadata and directory rename records before journal transitions.
# Plain sync is portable to the legacy CentOS 7 target.
durable_barrier() {
    sync || return 1
}

durable_set_state() {  # state-file value
    local state_file=$1 value=$2
    printf '%s\n' "$value" >"$state_file" || return 1
    durable_barrier
}

begin_runtime_transaction() {  # suffix prefix service
    local s=$1 parent state enabled
    RUNTIME_PREFIX=$2
    RUNTIME_SERVICE=$3
    RUNTIME_UNIT=${DABUILD_RUNTIME_UNIT_OVERRIDE:-/etc/systemd/system/$RUNTIME_SERVICE.service}
    parent="$WORK/transactions/runtime/php$s"; secure_root_dir "$parent"
    RUNTIME_TX_DIR=$(mktemp -d "$parent/run.XXXXXX") || die "Không tạo được runtime transaction"
    mkdir -p "$RUNTIME_TX_DIR/snapshot"
    printf '%s\n' "$RUNTIME_PREFIX" >"$RUNTIME_TX_DIR/runtime-prefix"
    printf '%s\n' "$RUNTIME_SERVICE" >"$RUNTIME_TX_DIR/runtime-service"
    printf '%s\n' "$RUNTIME_UNIT" >"$RUNTIME_TX_DIR/runtime-unit"
    state=$(systemctl is-active "$RUNTIME_SERVICE" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$RUNTIME_SERVICE" 2>/dev/null || true)
    printf '%s\n' "$state" >"$RUNTIME_TX_DIR/service-active"
    printf '%s\n' "$enabled" >"$RUNTIME_TX_DIR/service-enabled"
    if [ -e "$RUNTIME_UNIT" ] || [ -L "$RUNTIME_UNIT" ]; then
        cp -a "$RUNTIME_UNIT" "$RUNTIME_TX_DIR/snapshot/unit"
        printf 'PRESENT\n' >"$RUNTIME_TX_DIR/unit-state"
    else
        printf 'ABSENT\n' >"$RUNTIME_TX_DIR/unit-state"
    fi
    if [ -e "$RUNTIME_PREFIX" ] || [ -L "$RUNTIME_PREFIX" ]; then
        printf 'PRESENT\n' >"$RUNTIME_TX_DIR/prefix-state"
    else
        printf 'ABSENT\n' >"$RUNTIME_TX_DIR/prefix-state"
    fi
    durable_barrier || die "Không flush được metadata runtime transaction"
    durable_set_state "$RUNTIME_TX_DIR/state" PREPARED || die "Không ghi durable state PREPARED"
    RUNTIME_ACTIVE=1
}

stage_runtime_replacement() {
    local prefix_state
    prefix_state=$(tr -d '\n' <"$RUNTIME_TX_DIR/prefix-state")
    durable_set_state "$RUNTIME_TX_DIR/state" STAGING || die "Không ghi durable state STAGING"
    if [ "$prefix_state" = PRESENT ]; then
        mv "$RUNTIME_PREFIX" "$RUNTIME_TX_DIR/original-prefix" \
            || die "Không đưa runtime cũ vào transaction: $RUNTIME_PREFIX"
    fi
    if [ -e "$RUNTIME_UNIT" ] || [ -L "$RUNTIME_UNIT" ]; then
        mv "$RUNTIME_UNIT" "$RUNTIME_TX_DIR/original-unit" \
            || die "Không đưa systemd unit cũ vào transaction: $RUNTIME_UNIT"
    fi
    durable_barrier || die "Không flush được rename runtime/unit"
    durable_set_state "$RUNTIME_TX_DIR/state" STAGED || die "Không ghi durable state STAGED"
}

rollback_runtime() {
    local state prefix_state unit_state service_state enabled current_enabled q failed=0
    state=$(tr -d '\n' <"$RUNTIME_TX_DIR/state" 2>/dev/null || true)
    prefix_state=$(tr -d '\n' <"$RUNTIME_TX_DIR/prefix-state" 2>/dev/null || true)
    unit_state=$(tr -d '\n' <"$RUNTIME_TX_DIR/unit-state" 2>/dev/null || true)
    service_state=$(tr -d '\n' <"$RUNTIME_TX_DIR/service-active" 2>/dev/null || true)
    enabled=$(tr -d '\n' <"$RUNTIME_TX_DIR/service-enabled" 2>/dev/null || true)
    q=$(mktemp -d "$RUNTIME_TX_DIR/rollback-quarantine.XXXXXX") || return 1
    warn "Runtime transaction lỗi; khôi phục $RUNTIME_PREFIX"
    if [ "$prefix_state" = PRESENT ] && [ -e "$RUNTIME_TX_DIR/original-prefix" ]; then
        if [ -e "$RUNTIME_PREFIX" ] || [ -L "$RUNTIME_PREFIX" ]; then
            mv "$RUNTIME_PREFIX" "$q/failed-prefix" || failed=1
        fi
        [ "$failed" = 1 ] || mv "$RUNTIME_TX_DIR/original-prefix" "$RUNTIME_PREFIX" || failed=1
    elif [ "$prefix_state" = ABSENT ] && [ "$state" = STAGED ]; then
        if [ -e "$RUNTIME_PREFIX" ] || [ -L "$RUNTIME_PREFIX" ]; then
            mv "$RUNTIME_PREFIX" "$q/failed-prefix" || failed=1
        fi
    fi
    # For a first install, disable while the newly written unit still exists;
    # otherwise systemctl may leave a dangling wants/ symlink after unit removal.
    # A retry after partial rollback is idempotent: if both the unit and its
    # enablement are already absent, there is no remaining mutation to undo.
    case "$enabled" in
        not-found|'')
            current_enabled=$(systemctl is-enabled "$RUNTIME_SERVICE" 2>/dev/null || true)
            if [ -e "$RUNTIME_UNIT" ] || [ -L "$RUNTIME_UNIT" ] \
                || [ "$current_enabled" = enabled ] \
                || [ "$current_enabled" = enabled-runtime ]; then
                systemctl disable "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1
            fi
            ;;
    esac
    if [ -e "$RUNTIME_UNIT" ] || [ -L "$RUNTIME_UNIT" ]; then
        mv "$RUNTIME_UNIT" "$q/current-unit" || failed=1
    fi
    if [ "$unit_state" = PRESENT ]; then
        cp -a "$RUNTIME_TX_DIR/snapshot/unit" "$RUNTIME_UNIT" || failed=1
    elif [ "$unit_state" != ABSENT ]; then
        failed=1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    if [ "$service_state" = active ]; then
        systemctl restart "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1
        [ "$failed" = 1 ] || STOPPED_SERVICE=""
    elif systemctl is-active --quiet "$RUNTIME_SERVICE" 2>/dev/null; then
        systemctl stop "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1
    fi
    case "$enabled" in
        enabled) systemctl enable "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1 ;;
        enabled-runtime) systemctl enable --runtime "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1 ;;
        disabled) systemctl disable "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1 ;;
        masked) systemctl mask "$RUNTIME_SERVICE" >/dev/null 2>&1 || failed=1 ;;
        static|indirect|generated|not-found|'') ;;
        *) failed=1 ;;
    esac
    if [ "$failed" = 0 ]; then
        durable_barrier || failed=1
    fi
    if [ "$failed" = 0 ]; then
        durable_set_state "$RUNTIME_TX_DIR/state" ROLLED_BACK || failed=1
    fi
    if [ "$failed" = 0 ]; then
        RUNTIME_ACTIVE=0
        return 0
    fi
    return 1
}

commit_runtime_transaction() {
    durable_barrier || die "Không flush được runtime mới trước commit"
    durable_set_state "$RUNTIME_TX_DIR/state" COMMITTED || die "Không ghi durable runtime commit"
    record_change "runtime-commit" "prefix=$RUNTIME_PREFIX transaction=$RUNTIME_TX_DIR"
    RUNTIME_ACTIVE=0
}

restore_runtime_enablement_for_commit() {
    local enabled
    enabled=$(tr -d '\n' <"$RUNTIME_TX_DIR/service-enabled")
    case "$enabled" in
        enabled) systemctl enable "$RUNTIME_SERVICE" >/dev/null 2>&1 ;;
        enabled-runtime) systemctl enable --runtime "$RUNTIME_SERVICE" >/dev/null 2>&1 ;;
        disabled) systemctl disable "$RUNTIME_SERVICE" >/dev/null 2>&1 ;;
        not-found|'')
            if [ "$RESTART" = 1 ]; then
                systemctl enable "$RUNTIME_SERVICE" >/dev/null 2>&1
            else
                systemctl disable "$RUNTIME_SERVICE" >/dev/null 2>&1
            fi
            ;;
        static|indirect|generated) ;;
        *) die "Không thể giữ nguyên trạng thái enable '$enabled' của $RUNTIME_SERVICE" ;;
    esac
}

begin_extension_transaction() {  # suffix
    local s=$1 parent
    EXTENSION_BRANCH=$s
    parent="$WORK/transactions/extensions/php$s"; secure_root_dir "$parent"
    EXTENSION_TX_DIR=$(mktemp -d "$parent/run.XXXXXX") || die "Không tạo được transaction extension duy nhất"
    EXTENSION_SCOPE_LIST="$EXTENSION_TX_DIR/files.tsv"
    printf '%s\n' "$EXTENSION_BRANCH" >"$EXTENSION_TX_DIR/branch"
    mkdir -p "$EXTENSION_TX_DIR/snapshot"
    : >"$EXTENSION_SCOPE_LIST"
    seal_extension_scope || die "Không niêm phong được empty extension scope"
    durable_barrier || die "Không flush được extension transaction"
    durable_set_state "$EXTENSION_TX_DIR/state" PREPARED || die "Không ghi durable extension state"
    EXTENSION_ACTIVE=1
}

seal_extension_scope() {
    local tmp="$EXTENSION_TX_DIR/scope.sha256.tmp"
    [ -f "$EXTENSION_SCOPE_LIST" ] || return 1
    sha256sum "$EXTENSION_SCOPE_LIST" >"$tmp" || return 1
    mv -f "$tmp" "$EXTENSION_TX_DIR/scope.sha256"
}

extension_scope_backup() {
    local path=$1 rel
    backup_once "$path"
    awk -F '\t' -v path="$path" '$2 == path {found=1} END {exit !found}' "$EXTENSION_SCOPE_LIST" 2>/dev/null && return 0
    rel=${path#/}
    if [ -e "$path" ] || [ -L "$path" ]; then
        mkdir -p "$EXTENSION_TX_DIR/snapshot/$(dirname "$rel")"
        cp -a "$path" "$EXTENSION_TX_DIR/snapshot/$rel"
        printf 'P\t%s\n' "$path" >>"$EXTENSION_SCOPE_LIST"
    else
        printf 'A\t%s\n' "$path" >>"$EXTENSION_SCOPE_LIST"
    fi
    seal_extension_scope || die "Không niêm phong được extension scope"
}

arm_extension_mutation() {
    seal_extension_scope || die "Extension scope chưa sẵn sàng để mutation"
    durable_barrier || die "Không flush được extension scope trước mutation"
    durable_set_state "$EXTENSION_TX_DIR/state" STAGING || die "Không ghi durable extension STAGING"
}

finish_extension_mutation() {
    durable_barrier || die "Không flush được extension publication"
    durable_set_state "$EXTENSION_TX_DIR/state" STAGED || die "Không ghi durable extension STAGED"
}

rollback_extension() {
    local q kind path rel failed=0
    if [ ! -s "$EXTENSION_TX_DIR/scope.sha256" ] || \
       ! sha256sum -c "$EXTENSION_TX_DIR/scope.sha256" >/dev/null 2>&1; then
        warn "Extension scope thiếu hoặc sai checksum; từ chối rollback không đầy đủ: $EXTENSION_TX_DIR"
        return 1
    fi
    q=$(mktemp -d "$EXTENSION_TX_DIR/rollback-quarantine.XXXXXX") \
        || { warn "Không tạo được quarantine rollback extension"; return 1; }
    warn "Extension PHP $EXTENSION_BRANCH lỗi; khôi phục trạng thái ngay trước transaction"
    if [ -f "$EXTENSION_SCOPE_LIST" ]; then
        while IFS=$'\t' read -r kind path; do
            [ -n "$path" ] || continue
            rel=${path#/}
            case "$kind" in
                P)
                    if [ -e "$EXTENSION_TX_DIR/snapshot/$rel" ] || [ -L "$EXTENSION_TX_DIR/snapshot/$rel" ]; then
                        if [ -e "$path" ] || [ -L "$path" ]; then
                            mkdir -p "$q/replaced/$(dirname "$rel")"
                            mv "$path" "$q/replaced/$rel" || { failed=1; continue; }
                        fi
                        mkdir -p "$(dirname "$path")"
                        cp -a "$EXTENSION_TX_DIR/snapshot/$rel" "$path" || failed=1
                    else
                        warn "Thiếu snapshot transaction: $EXTENSION_TX_DIR/snapshot/$rel"
                        failed=1
                    fi
                    ;;
                A)
                    if [ -e "$path" ] || [ -L "$path" ]; then
                        mkdir -p "$q/$(dirname "$rel")"
                        mv "$path" "$q/$rel" || failed=1
                    fi
                    ;;
                *) warn "Bản ghi transaction extension không hợp lệ: $kind $path"; failed=1 ;;
            esac
        done <"$EXTENSION_SCOPE_LIST"
    else
        warn "Thiếu scope list của extension transaction: $EXTENSION_SCOPE_LIST"
        failed=1
    fi
    record_change "extension-rollback-php$EXTENSION_BRANCH" "transaction=$EXTENSION_TX_DIR quarantine=$q failed=$failed"
    if [ "$failed" = 0 ]; then
        durable_barrier || failed=1
    fi
    if [ "$failed" = 0 ]; then
        durable_set_state "$EXTENSION_TX_DIR/state" ROLLED_BACK || failed=1
    fi
    if [ "$failed" = 0 ]; then
        EXTENSION_ACTIVE=0
        return 0
    fi
    return 1
}

commit_extension_transaction() {
    record_change "extension-commit-php$EXTENSION_BRANCH" "transaction=$EXTENSION_TX_DIR scope_list=$EXTENSION_SCOPE_LIST"
    durable_barrier || die "Không flush được extension trước commit"
    durable_set_state "$EXTENSION_TX_DIR/state" COMMITTED || die "Không ghi durable extension commit"
    EXTENSION_ACTIVE=0
}

extension_load_files() {  # extension php.ini conf.d/*.ini
    local ext=$1; shift
    local f
    local -a files=()
    for f in "$@"; do
        [ -f "$f" ] && files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    awk -v ext="$ext" '
        /^[[:space:]]*extension[[:space:]]*=/ {
            value=$0
            sub(/^[[:space:]]*extension[[:space:]]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*;.*/, "", value)
            gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", value)
            count=split(value, part, "/")
            base=part[count]
            if (base == ext || base == ext ".so") print FILENAME
        }
    ' "${files[@]}"
}

php_tool() {  # prefix suffix tool
    local P=$1 s=$2 tool=$3
    if [ -x "$P/bin/${tool}${s}" ]; then printf '%s\n' "$P/bin/${tool}${s}"
    elif [ -x "$P/bin/$tool" ]; then printf '%s\n' "$P/bin/$tool"
    else return 1
    fi
}

build_one_extension() {  # branch extension
    local v=$1 ext=$2 s=${1/./} P=/usr/local/php${1/./}
    local ver archive php phpize php_config ext_dir so ini build_name tmp load_count load_list
    php=$(php_tool "$P" "$s" php) || die "Không thấy PHP CLI trong $P"
    phpize=$(php_tool "$P" "$s" phpize) || die "Không thấy phpize trong $P"
    php_config=$(php_tool "$P" "$s" php-config) || die "Không thấy php-config trong $P"
    case "$ext" in
        redis)   ver=$REDIS_VERSION; archive="redis-$ver.tgz" ;;
        imagick) ver=$IMAGICK_VERSION; archive="imagick-$ver.tgz"
                 command -v MagickWand-config >/dev/null 2>&1 || die "Thiếu MagickWand-config; cần ImageMagick development files trước khi build Imagick." ;;
        *) die "Extension không hỗ trợ: $ext" ;;
    esac
    build_name="ext-$ext-$ver-php$s"
    CUR=$build_name
    log "Build $ext $ver cho PHP $v"
    fetch_extract "$archive" "$build_name"
    cd "$WORK/$build_name"
    if [ "$ext" = redis ] && [ "${GCC_MAJOR:-0}" -lt 10 ]; then
        local redis_patch="$WORK/$build_name-gcc48.patch"
        cat >"$redis_patch" <<'PATCH_EOF'
--- a/common.h
+++ b/common.h
@@ -46,7 +46,10 @@
 #endif
 
 #ifndef REDIS_MSVC
-#  if defined(__has_c_attribute)
+#  if defined(__GNUC__) && __GNUC__ < 10
+#    define REDIS_NODISCARD __attribute__((warn_unused_result))
+#  endif
+#  if defined(__has_c_attribute) && (!defined(__GNUC__) || __GNUC__ >= 10)
 #    if __has_c_attribute(nodiscard)
 #      define REDIS_NODISCARD [[nodiscard]]
 #    endif
PATCH_EOF
        run "vá Redis $ver cho GCC cũ" patch -p1 -i "$redis_patch"
    fi
    run "phpize $ext cho PHP $v" "$phpize"
    if [ "$ext" = imagick ]; then
        run "configure $ext cho PHP $v" env CFLAGS="-O2 -fPIC -std=gnu99" ./configure --with-php-config="$php_config" --with-imagick=/usr/local
    else
        run "configure $ext cho PHP $v" env CFLAGS="-O2 -fPIC -std=gnu99" ./configure --with-php-config="$php_config"
    fi
    run "make $ext cho PHP $v" make -j"$JOBS"
    so="$WORK/$build_name/modules/$ext.so"
    [ -s "$so" ] || die "Không tạo được $so"
    ext_dir=$($php_config --extension-dir)
    case "$ext_dir" in "$P"/*) ;; *) die "extension_dir thoát khỏi prefix $P: $ext_dir" ;; esac
    local conf_dir="$P/lib/php.conf.d" module_tmp ini_tmp=""
    local -a load_ini=()
    load_list="$WORK/$build_name-extension-loaders.list"
    extension_load_files "$ext" "$P/lib/php.ini" "$P"/lib/php.conf.d/*.ini >"$load_list" \
        || die "Không đọc được cấu hình INI để kiểm tra loader $ext"
    while IFS= read -r ini; do [ -n "$ini" ] && load_ini+=("$ini"); done <"$load_list"
    load_count=${#load_ini[@]}
    [ "$load_count" -le 1 ] || die "$ext đang được khai báo lặp ($load_count dòng) trong: ${load_ini[*]}"
    if [ "${#load_ini[@]}" -eq 1 ]; then
        ini=${load_ini[0]}
    else
        ini="$conf_dir/20-$ext.ini"
    fi
    [ -e "$ext_dir" ] || [ -L "$ext_dir" ] || extension_scope_backup "$ext_dir"
    [ -e "$conf_dir" ] || [ -L "$conf_dir" ] || extension_scope_backup "$conf_dir"
    extension_scope_backup "$ext_dir/$ext.so"
    [ "${#load_ini[@]}" -eq 1 ] || extension_scope_backup "$ini"
    module_tmp="$ext_dir/.$ext.so.dabuild.$(basename "$EXTENSION_TX_DIR").$RANDOM"
    extension_scope_backup "$module_tmp"
    if [ "${#load_ini[@]}" -eq 0 ]; then
        ini_tmp="$conf_dir/.20-$ext.ini.dabuild.$(basename "$EXTENSION_TX_DIR").$RANDOM"
        extension_scope_backup "$ini_tmp"
    fi
    arm_extension_mutation
    mkdir -p "$ext_dir" "$conf_dir"
    install -m 0755 "$so" "$module_tmp"
    mv -f "$module_tmp" "$ext_dir/$ext.so"
    if [ "${#load_ini[@]}" -eq 1 ]; then
        log "  - giữ khai báo $ext hiện có: $ini"
    else
        printf 'extension=%s\n' "$ext" >"$ini_tmp"
        chmod 0644 "$ini_tmp"
        mv -f "$ini_tmp" "$ini"
    fi
    finish_extension_mutation
    "$php" -n -d "extension=$ext_dir/$ext.so" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext" \
        || die "$ext.so không load độc lập được trên PHP $v"
    record_change "extension-php$s" "installed=$ext version=$ver so=$ext_dir/$ext.so ini=$ini"
}

install_extensions_for_php() {  # branch
    local v=$1 ext s=${1/./} P=/usr/local/php${1/./} php startup
    [ -n "${PHPV[$v]:-}" ] || die "Không hỗ trợ PHP '$v'"
    php=$(php_tool "$P" "$s" php) || die "PHP $v chưa được cài tại $P"
    begin_extension_transaction "$s"
    for ext in redis imagick; do build_one_extension "$v" "$ext"; done
    startup=$("$php" -v 2>&1) || die "PHP $v không khởi động được sau khi cài extension"
    if grep -Eq 'PHP (Warning|Startup|Fatal error)|already loaded|Unable to load' <<<"$startup"; then
        printf '%s\n' "$startup" >&2
        die "PHP $v có startup warning sau khi cài extension"
    fi
    "$php" -r '
        foreach (["redis", "imagick"] as $e) {
            if (!extension_loaded($e)) { fwrite(STDERR, "missing:$e\\n"); exit(1); }
        }
        printf("redis=%s imagick=%s ImageMagick=%s\\n",
            phpversion("redis"), phpversion("imagick"), Imagick::getVersion()["versionString"]);
    ' || die "Kiểm tra Redis/Imagick thất bại trên PHP $v"
}

extensions_cmd() {
    local v s svc was_active
    [ "$#" -gt 0 ] || die "Dùng: $0 extensions 8.4 | extensions all"
    [ "$1" != all ] || set -- $BRANCHES
    preflight; prepare_dirs; acquire_integration_lock; toolchain
    for v in "$@"; do
        [ -n "${PHPV[$v]:-}" ] || die "Không hỗ trợ PHP '$v'"
        s=${v/./}; svc=php-fpm$s; was_active=0
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            was_active=1
            STOPPED_SERVICE=$svc
            log "Dừng $svc trong lúc thay module"
            systemctl stop "$svc"
        fi
        if ! install_extensions_for_php "$v"; then
            [ "$was_active" = 1 ] && systemctl start "$svc" 2>/dev/null || true
            die "Cài extension cho PHP $v thất bại; baseline: $BACKUP_ROOT/$(date +%F)"
        fi
        if [ "$was_active" = 1 ]; then
            systemctl start "$svc" || die "Không khởi động lại được $svc"
            STOPPED_SERVICE=""
        fi
        systemctl is-active --quiet "$svc" 2>/dev/null || warn "$svc không active trước thao tác nên không tự start"
        commit_extension_transaction
        log "Redis + Imagick cho PHP $v: OK"
    done
}

write_fpm_conf() {  # prefix suffix
    local P=$1 s=$2
    mkdir -p "$P/etc" "$P/sockets" "$P/var/log" "$P/var/run" "$P/lib/php.conf.d"
    chown root:root "$P/sockets"; chmod 0755 "$P/sockets"
    cat >"$P/etc/php-fpm.conf" <<EOF
[global]
error_log = log/php-fpm.log

; syslog_facility is used to specify what type of program is logging the
; message. This lets syslogd specify that messages from different facilities
; will be handled differently.
; See syslog(3) for possible values (ex daemon equiv LOG_DAEMON)
; Default Value: daemon
;syslog.facility = daemon

; syslog_ident is prepended to every message. If you have multiple FPM
; instances running on the same server, you can change the default value.
; Default Value: php-fpm
;syslog.ident = php-fpm

; Log level
; Possible Values: alert, error, warning, notice, debug
; Default Value: notice
log_level = notice

;;;;;;;;;;;;;;;;;;;;
; Pool Definitions ;
;;;;;;;;;;;;;;;;;;;;

; Based on the DirectAdmin CustomBuild php-fpm.conf layout.
; The stock [webapps] fallback pool is intentionally not published here.
; DirectAdmin integration creates one isolated pool/socket per selected account.
; Pool-specific listen/pm/security settings are loaded from DirectAdmin user files below.
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
    local pool_count=0
    local -a bins=("$php")
    if [ -x "$P/sbin/php-fpm$s" ]; then bins+=("$P/sbin/php-fpm$s"); fi
    if [ -x "$P/bin/lsphp$s" ];    then bins+=("$P/bin/lsphp$s"); fi
    log "Kiểm tra PHP $v"
    "$php" -v 2>&1 | sed -n '1,2p'
    for m in intl openssl curl mbstring gd zip sqlite3 pdo_sqlite gmp dom xsl mysqli pdo_mysql bcmath sockets soap "Zend OPcache" redis imagick; do
        "$php" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$m" || { warn "Thiếu module: $m"; bad=1; }
    done
    log "  ICU: $("$php" -r 'echo INTL_ICU_VERSION;' 2>/dev/null)  OpenSSL: $("$php" -r 'echo OPENSSL_VERSION_TEXT;' 2>/dev/null)"
    [ "$("$php" -r 'echo phpversion("redis");' 2>/dev/null)" = "$REDIS_VERSION" ] \
        || { warn "Redis không đúng version $REDIS_VERSION"; bad=1; }
    [ "$("$php" -r 'echo phpversion("imagick");' 2>/dev/null)" = "$IMAGICK_VERSION" ] \
        || { warn "Imagick không đúng version $IMAGICK_VERSION"; bad=1; }
    if ldd "${bins[@]}" 2>&1 | grep -q 'not found'; then
        ldd "${bins[@]}" 2>&1 | grep 'not found' >&2
        die "Thiếu thư viện runtime (xem ở trên)"
    fi
    if ! ldd "$php" | grep -q "libssl.so.1.1 => $DEPS/"; then
        warn "php$s không link OpenSSL 1.1.1 trong $DEPS (kiểm tra ldd)"; bad=1
    fi
    if [ -x "$P/sbin/php-fpm$s" ]; then
        pool_count=$(find /usr/local/directadmin/data/users -path "*/php/php-fpm$s.conf" -type f 2>/dev/null | wc -l)
        validate_no_shared_pool_effective "$P/etc/php-fpm.conf" \
            "/usr/local/directadmin/data/users/*/php/php-fpm$s.conf" \
            || die "FPM config PHP $v còn shared [webapps]/webapps.sock"
        if [ "$pool_count" -eq 0 ]; then
            warn "PHP $v mới ở trạng thái runtime-only: chưa có pool DirectAdmin php-fpm$s. Service phải giữ inactive cho đến khi integrate tạo pool riêng theo user."
        else
            "$P/sbin/php-fpm$s" -t >/dev/null 2>&1 \
                || die "php-fpm$s -t thất bại với per-user pools"
            log "  DirectAdmin user pools: $pool_count"
        fi
    fi
    if [ -x "$P/bin/lsphp$s" ]; then
        log "  lsphp: $("$P/bin/lsphp$s" -v 2>&1 | sed -n '1p')"
    fi
    [ "$bad" = 0 ] || die "PHP $v thiếu module hoặc sai runtime linkage; xem cảnh báo phía trên"
    log "PHP $v: OK"
}

# Lấy binary lsphp từ cây source (chạy trong thư mục source, sau make install).
# Không phụ thuộc việc 'make install' đặt tên là lsphp hay lsphpXX; chuyển bản cũ vào quarantine trước khi chép
# để tránh "Text file busy" khi OLS đang chạy lsphp cũ.
install_lsphp() {  # prefix suffix
    local P=$1 s=$2 c b=""
    for c in sapi/litespeed/php sapi/litespeed/lsphp; do
        if [ -x "$c" ]; then b=$c; break; fi
    done
    [ -n "$b" ] || die "Không thấy binary lsphp trong sapi/litespeed/ (configure có --enable-litespeed không?)"
    quarantine_existing "$P/bin/lsphp" lsphp-refresh
    quarantine_existing "$P/bin/lsphp$s" lsphp-refresh
    install -m 0755 "$b" "$P/bin/lsphp$s"
    ln -sfn "lsphp$s" "$P/bin/lsphp"
}

build_php() {
    local v=$1 full s P f svc was_active=0 fpm=0 lsp=0 pool_count=0
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

    begin_runtime_transaction "$s" "$P" "$svc"
    # dừng service ngay trước khi thay binary để downtime tối thiểu (chỉ áp dụng cho FPM)
    if [ "$fpm" = 1 ] && systemctl is-active --quiet "$svc" 2>/dev/null; then
        was_active=1; STOPPED_SERVICE=$svc; log "Dừng $svc để thay binary"; systemctl stop "$svc"
    fi
    stage_runtime_replacement
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
    if [ "$INSTALL_EXTENSIONS" = 1 ]; then
        install_extensions_for_php "$v"
    fi
    if [ "$fpm" = 1 ]; then
        write_unit "$s"
        systemctl daemon-reload
    fi
    verify_php "$v" "$P" "$s"

    if [ "$fpm" = 1 ]; then
        pool_count=$(find /usr/local/directadmin/data/users -path "*/php/php-fpm$s.conf" -type f 2>/dev/null | wc -l)
        if [ "$was_active" = 1 ] || [ "$RESTART" = 1 ]; then
            [ "$pool_count" -gt 0 ] \
                || die "Từ chối start $svc: chưa có per-user pool. Hãy giữ service inactive và chạy integrate trước."
            systemctl restart "$svc" && { STOPPED_SERVICE=""; log "Đã restart $svc"; } || die "Restart $svc lỗi: journalctl -u $svc"
        else
            log "Chưa start service. Chỉ start sau khi lệnh integrate tạo per-user pool/socket."
        fi
        restore_runtime_enablement_for_commit \
            || die "Không khôi phục được trạng thái enable của $svc"
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
    if [ "$INSTALL_EXTENSIONS" = 1 ]; then
        commit_extension_transaction
    fi
    commit_runtime_transaction
    log "===== PHP $full xong ====="
}

# ---------------------------------------------------------------- tích hợp DirectAdmin
get_da_option() {
    awk -F= -v key="$1" '$1 == key {gsub(/\r/, "", $2); print $2; exit}' "$DA_OPTIONS"
}

set_kv() {  # regular-file key value
    local file=$1 key=$2 value=$3 tmp count context
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    count=$(awk -v key="$key" '
        { pos=index($0, "="); if (pos && substr($0, 1, pos - 1) == key) found++ }
        END { print found+0 }
    ' "$file") || return 1
    [ "$count" -le 1 ] || return 1
    tmp="$file.dabuild.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    awk -v key="$key" -v value="$value" '
        BEGIN { changed=0 }
        {
            pos=index($0, "=")
            if (pos && substr($0, 1, pos - 1) == key) {
                print key "=" value
                changed=1
                next
            }
            print
        }
        END { if (!changed) print key "=" value }
    ' "$file" >"$tmp" || return 1
    chmod --reference="$file" "$tmp" || return 1
    chown --reference="$file" "$tmp" || return 1
    context=$(capture_selinux_context "$file") || return 1
    case "$context" in
        __NO_SELINUX_CONTEXT__) ;;
        *) command -v chcon >/dev/null 2>&1 && chcon "$context" "$tmp" || return 1 ;;
    esac
    mv -f "$tmp" "$file"
}

kv_get() {  # file key; reject ambiguous duplicates
    local file=$1 key=$2
    awk -v key="$key" '
        {
            pos=index($0, "=")
            if (!pos || substr($0, 1, pos - 1) != key) next
            value=substr($0, pos + 1)
            sub(/\r$/, "", value)
            found++
            if (found == 1) result=value
        }
        END {
            if (found > 1) exit 2
            if (found == 1) print result
        }
    ' "$file"
}

systemctl_property() {  # service property; require one exact property line
    local service=$1 property=$2 output count
    [[ "$property" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
    output=$(systemctl show -p "$property" "$service" 2>/dev/null) || return 1
    count=$(printf '%s\n' "$output" | awk -F= -v key="$property" '$1 == key {n++} END {print n+0}') \
        || return 1
    [ "$count" = 1 ] || return 1
    printf '%s\n' "$output" | awk -F= -v key="$property" '$1 == key {print substr($0, index($0, "=") + 1)}'
}

begin_integration_transaction() {  # suffix
    local s=$1 parent
    parent="$WORK/transactions/integration/php$s"; secure_root_dir "$parent"
    INTEGRATION_TX_DIR=$(mktemp -d "$parent/run.XXXXXX") || die "Không tạo được transaction integration duy nhất"
    INTEGRATION_SCOPE_LIST="$INTEGRATION_TX_DIR/files.tsv"
    INTEGRATION_PRE_REWRITE_LIST="$INTEGRATION_TX_DIR/pre-rewrite-paths.list0"
    mkdir -p "$INTEGRATION_TX_DIR/snapshot"
    : >"$INTEGRATION_SCOPE_LIST"
    seal_integration_scope || die "Không niêm phong được empty integration scope"
    durable_barrier || die "Không flush được integration transaction"
    durable_set_state "$INTEGRATION_TX_DIR/state" PREPARED || die "Không ghi durable integration state"
    INTEGRATION_ACTIVE=1
}

capture_rewrite_inventory() {  # output-list0
    local out=$1
    local -a webroots=() systemd_roots=()
    : >"$out"
    if [ -d /usr/local/directadmin/data/users ]; then
        find /usr/local/directadmin/data/users \
            \( \( -type f -o -type l \) \( -name '*.conf' -o -name 'domains.list' \) -o -type d \) \
            -print0 >>"$out" 2>/dev/null || return 1
    fi
    [ -d /etc/httpd/conf ] && webroots+=(/etc/httpd/conf)
    [ -d /etc/nginx ] && webroots+=(/etc/nginx)
    [ "${#webroots[@]}" -gt 0 ] || return 1
    find "${webroots[@]}" \( -type f -o -type l -o -type d \) -print0 >>"$out" 2>/dev/null \
        || return 1
    [ -d /etc/systemd/system ] && systemd_roots+=(/etc/systemd/system)
    [ -d /usr/lib/systemd/system ] && systemd_roots+=(/usr/lib/systemd/system)
    if [ "${#systemd_roots[@]}" -gt 0 ]; then
        find "${systemd_roots[@]}" \( -type f -o -type l -o -type d \) \
            \( -name 'php-fpm*.service' -o -name 'php-fpm*.service.d' -o -path '*/php-fpm*.service.d/*' \) \
            -print0 >>"$out" 2>/dev/null || return 1
    fi
}

record_rewrite_created_paths() {
    local current="$INTEGRATION_TX_DIR/post-rewrite-paths.list0" path
    capture_rewrite_inventory "$current" || die "Không inventory được cấu hình sau rewrite_confs"
    while IFS= read -r -d '' path; do
        if ! grep -Fzxq -- "$path" "$INTEGRATION_PRE_REWRITE_LIST"; then
            awk -F '\t' -v path="$path" '$2 == path {found=1} END {exit !found}' \
                "$INTEGRATION_SCOPE_LIST" 2>/dev/null \
                || printf 'A\t%s\n' "$path" >>"$INTEGRATION_SCOPE_LIST"
        fi
    done <"$current"
    seal_integration_scope || die "Không niêm phong được scope sau rewrite_confs"
}

run_rewrite_confs_transactional() {
    local rc
    log "  - DirectAdmin rewrite_confs"
    mkdir -p "$LOGS"
    printf '\n### DirectAdmin rewrite_confs\n### %s rewrite_confs\n' "$DA_CB/build" >>"$LOGS/$CUR.log"
    if "$DA_CB/build" rewrite_confs >>"$LOGS/$CUR.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    # rewrite_confs có thể tạo file rồi mới trả lỗi; inventory phải chạy ở cả hai nhánh.
    record_rewrite_created_paths
    [ "$rc" -eq 0 ] || die "DirectAdmin rewrite_confs lỗi (exit=$rc). Log: $LOGS/$CUR.log"
}

seal_integration_scope() {
    local tmp="$INTEGRATION_TX_DIR/scope.sha256.tmp"
    [ -f "$INTEGRATION_SCOPE_LIST" ] || return 1
    sha256sum "$INTEGRATION_SCOPE_LIST" >"$tmp" || return 1
    mv -f "$tmp" "$INTEGRATION_TX_DIR/scope.sha256"
}

directory_meta_path() {
    local path=$1 digest
    digest=$(printf '%s' "$path" | sha256sum | awk '{print $1}') \
        || return 1
    [ -n "$digest" ] || return 1
    printf '%s/dir-meta/%s.meta\n' "$INTEGRATION_TX_DIR" "$digest"
}

capture_selinux_context() {
    local path=$1 context
    if context=$(stat -Lc '%C' "$path" 2>/dev/null); then
        if [ -n "$context" ] && [ "$context" != '?' ]; then
            printf '%s\n' "$context"
            return 0
        fi
    fi
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        return 1
    fi
    printf '%s\n' '__NO_SELINUX_CONTEXT__'
}

scope_backup() {
    local path=$1 rel snap meta context mode uid gid atime mtime
    awk -F '\t' -v path="$path" '$2 == path {found=1} END {exit !found}' "$INTEGRATION_SCOPE_LIST" 2>/dev/null && return 0
    rel=${path#/}
    snap="$INTEGRATION_TX_DIR/snapshot/$rel"
    if [ -d "$path" ] && [ ! -L "$path" ]; then
        meta=$(directory_meta_path "$path") || die "Không tạo được khóa directory metadata: $path"
        mkdir -p "$(dirname "$meta")"
        mode=$(stat -Lc '%a' "$path") || die "Không đọc được mode directory: $path"
        uid=$(stat -Lc '%u' "$path") || die "Không đọc được owner directory: $path"
        gid=$(stat -Lc '%g' "$path") || die "Không đọc được group directory: $path"
        atime=$(stat -Lc '%x' "$path") || die "Không đọc được atime directory: $path"
        mtime=$(stat -Lc '%y' "$path") || die "Không đọc được mtime directory: $path"
        context=$(capture_selinux_context "$path") \
            || die "Không capture được SELinux context directory: $path"
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
            "$mode" "$uid" "$gid" "$atime" "$mtime" "$context" >"$meta" \
            || die "Không snapshot được directory metadata: $path"
        printf 'D\t%s\n' "$path" >>"$INTEGRATION_SCOPE_LIST"
    elif [ -e "$path" ] || [ -L "$path" ]; then
        backup_once "$path"
        mkdir -p "$INTEGRATION_TX_DIR/snapshot/$(dirname "$rel")"
        cp -a "$path" "$snap"
        printf 'P\t%s\n' "$path" >>"$INTEGRATION_SCOPE_LIST"
    else
        backup_once "$path"
        printf 'A\t%s\n' "$path" >>"$INTEGRATION_SCOPE_LIST"
    fi
    seal_integration_scope || die "Không niêm phong được integration scope"
}

snapshot_rewrite_inventory() {  # NUL-delimited inventory
    local list=$1 path
    while IFS= read -r -d '' path; do scope_backup "$path"; done <"$list"
}

backup_integration_scope() {  # suffix
    local s=$1 f v vs user_dir list
    local -a webroots=()
    begin_integration_transaction "$s"
    scope_backup "$DA_OPTIONS"
    scope_backup "$DA_CB/build"
    scope_backup "$DA_CB/custom_versions.txt"
    scope_backup "/usr/local/directadmin/data/admin/services.status"
    capture_rewrite_inventory "$INTEGRATION_PRE_REWRITE_LIST" \
        || die "Không tạo được inventory trước rewrite_confs"
    snapshot_rewrite_inventory "$INTEGRATION_PRE_REWRITE_LIST"
    list="$INTEGRATION_TX_DIR/directadmin-files.list0"
    find /usr/local/directadmin/data/users -type f \
        \( -name '*.conf' -o -name 'domains.list' \) -print0 >"$list" 2>/dev/null \
        || die "Không inventory được cấu hình DirectAdmin users"
    while IFS= read -r -d '' f; do scope_backup "$f"; done <"$list"
    list="$INTEGRATION_TX_DIR/webserver-files.list0"
    [ -d /etc/httpd/conf ] && webroots+=(/etc/httpd/conf)
    [ -d /etc/nginx ] && webroots+=(/etc/nginx)
    [ "${#webroots[@]}" -gt 0 ] || die "Không tìm thấy thư mục cấu hình webserver"
    find "${webroots[@]}" -type f -print0 >"$list" 2>/dev/null \
        || die "Không inventory được cấu hình webserver"
    while IFS= read -r -d '' f; do scope_backup "$f"; done <"$list"
    for user_dir in /usr/local/directadmin/data/users/*; do
        [ -d "$user_dir" ] || continue
        scope_backup "$user_dir/php/php-fpm$s.conf"
    done
    for f in /usr/local/php*/etc/php-fpm.conf; do
        [ -f "$f" ] && scope_backup "$f"
    done
    scope_backup "/usr/local/php$s/etc/php-fpm.conf"
    scope_backup "$DA_CB/custom/fpm/conf/php-fpm.conf.$s"
    for f in /etc/systemd/system/php-fpm*.service; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        scope_backup "$f"
    done
    for v in $BRANCHES; do
        vs=${v/./}
        scope_backup "/etc/systemd/system/php-fpm$vs.service"
    done
}

arm_integration_mutation() {
    [ -s "$INTEGRATION_PRE_REWRITE_LIST" ] || die "Thiếu pre-rewrite inventory"
    [ -s "$INTEGRATION_TX_DIR/services.tsv" ] || die "Thiếu service-state journal"
    seal_integration_scope || die "Integration scope chưa sẵn sàng để mutation"
    durable_barrier || die "Không flush được integration journal trước mutation"
    durable_set_state "$INTEGRATION_TX_DIR/state" STAGING || die "Không ghi durable integration STAGING"
}

finish_integration_mutation() {
    durable_barrier || die "Không flush được integration publication"
    durable_set_state "$INTEGRATION_TX_DIR/state" STAGED || die "Không ghi durable integration STAGED"
}

rollback_integration() {
    local q kind path rel entry service state enabled failed=0 tx_state meta mode uid gid atime mtime context
    if [ ! -s "$INTEGRATION_TX_DIR/scope.sha256" ] || \
       ! sha256sum -c "$INTEGRATION_TX_DIR/scope.sha256" >/dev/null 2>&1; then
        warn "Integration scope thiếu hoặc sai checksum; từ chối rollback không đầy đủ: $INTEGRATION_TX_DIR"
        return 1
    fi
    tx_state=$(tr -d '\n' <"$INTEGRATION_TX_DIR/state" 2>/dev/null || true)
    case "$tx_state" in
        STAGING|STAGED)
            # rewrite_confs có thể bị mất điện trước post-inventory. Reconcile
            # mọi path mới dưới scope đã allowlist trước khi rollback.
            record_rewrite_created_paths
            durable_barrier || return 1
            ;;
    esac
    if [ ! -s "$INTEGRATION_TX_DIR/scope.sha256" ] || \
       ! sha256sum -c "$INTEGRATION_TX_DIR/scope.sha256" >/dev/null 2>&1; then
        warn "Integration scope sau crash-reconcile không hợp lệ: $INTEGRATION_TX_DIR"
        return 1
    fi
    q=$(mktemp -d "$INTEGRATION_TX_DIR/rollback-quarantine.XXXXXX") \
        || { warn "Không tạo được quarantine rollback"; return 1; }
    warn "Integration lỗi; khôi phục trạng thái ngay trước transaction"
    if [ -f "$INTEGRATION_SCOPE_LIST" ]; then
        # Restore directory shape first so child files/symlinks have valid parents.
        while IFS=$'\t' read -r kind path; do
            [ "$kind" = D ] || continue
            rel=${path#/}
            if [ -e "$path" ] || [ -L "$path" ]; then
                if [ ! -d "$path" ] || [ -L "$path" ]; then
                    mkdir -p "$q/replaced/$(dirname "$rel")"
                    mv "$path" "$q/replaced/$rel" || { failed=1; continue; }
                    mkdir -p "$path" || failed=1
                fi
            else
                mkdir -p "$path" || failed=1
            fi
        done <"$INTEGRATION_SCOPE_LIST"
        while IFS=$'\t' read -r kind path; do
            [ -n "$path" ] || continue
            rel=${path#/}
            case "$kind" in
                P)
                    if [ -e "$INTEGRATION_TX_DIR/snapshot/$rel" ] || [ -L "$INTEGRATION_TX_DIR/snapshot/$rel" ]; then
                        if [ -e "$path" ] || [ -L "$path" ]; then
                            mkdir -p "$q/replaced/$(dirname "$rel")"
                            mv "$path" "$q/replaced/$rel" || { failed=1; continue; }
                        fi
                        mkdir -p "$(dirname "$path")"
                        cp -a "$INTEGRATION_TX_DIR/snapshot/$rel" "$path" || failed=1
                    else
                        warn "Thiếu snapshot integration: $INTEGRATION_TX_DIR/snapshot/$rel"
                        failed=1
                    fi
                    ;;
                A)
                    if [ -e "$path" ] || [ -L "$path" ]; then
                        mkdir -p "$q/$(dirname "$rel")"
                        mv "$path" "$q/$rel" || failed=1
                    fi
                    ;;
                D) ;;
                *) warn "Bản ghi transaction integration không hợp lệ: $kind $path"; failed=1 ;;
            esac
        done <"$INTEGRATION_SCOPE_LIST"
        # Apply directory metadata last because child restoration changes mtime.
        while IFS=$'\t' read -r kind path; do
            [ "$kind" = D ] || continue
            rel=${path#/}
            meta=$(directory_meta_path "$path") || { failed=1; continue; }
            if [ -d "$path" ] && [ ! -L "$path" ] && [ -s "$meta" ]; then
                mode=$(sed -n '1p' "$meta")
                uid=$(sed -n '2p' "$meta")
                gid=$(sed -n '3p' "$meta")
                atime=$(sed -n '4p' "$meta")
                mtime=$(sed -n '5p' "$meta")
                context=$(sed -n '6p' "$meta")
                case "$mode:$uid:$gid" in
                    *[!0-9:]*|::*|:*:|:*) warn "Directory metadata không hợp lệ: $path"; failed=1; continue ;;
                esac
                [ -n "$atime" ] && [ -n "$mtime" ] \
                    || { warn "Directory timestamp metadata không hợp lệ: $path"; failed=1; continue; }
                chmod "$mode" "$path" || failed=1
                chown "$uid:$gid" "$path" || failed=1
                touch -a -d "$atime" "$path" || failed=1
                touch -m -d "$mtime" "$path" || failed=1
                case "$context" in
                    __NO_SELINUX_CONTEXT__) ;;
                    ''|'?') warn "SELinux context metadata không hợp lệ: $path"; failed=1 ;;
                    *)
                        if ! command -v chcon >/dev/null 2>&1 || ! chcon "$context" "$path"; then
                            warn "Không khôi phục được SELinux context: $path"
                            failed=1
                        fi
                        ;;
                esac
            else
                warn "Thiếu directory metadata snapshot: $path"
                failed=1
            fi
        done <"$INTEGRATION_SCOPE_LIST"
    else
        warn "Thiếu scope list của integration transaction: $INTEGRATION_SCOPE_LIST"
        failed=1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    for entry in $INTEGRATION_SERVICE_STATES; do
        IFS=: read -r service state enabled <<<"$entry"
        if [ "$state" = active ]; then
            systemctl restart "$service" >/dev/null 2>&1 || { warn "Không restart lại được $service"; failed=1; }
        elif systemctl is-active --quiet "$service" 2>/dev/null; then
            systemctl stop "$service" >/dev/null 2>&1 || { warn "Không trả $service về trạng thái $state"; failed=1; }
        fi
        case "$enabled" in
            enabled) systemctl enable "$service" >/dev/null 2>&1 || { warn "Không enable lại được $service"; failed=1; } ;;
            disabled) systemctl disable "$service" >/dev/null 2>&1 || { warn "Không disable lại được $service"; failed=1; } ;;
            masked) systemctl mask "$service" >/dev/null 2>&1 || { warn "Không mask lại được $service"; failed=1; } ;;
            static|indirect|generated|not-found) ;;
            *) warn "Trạng thái enable rollback không hợp lệ: $service=$enabled"; failed=1 ;;
        esac
    done
    record_change "integration-rollback" "transaction=$INTEGRATION_TX_DIR quarantine=$q failed=$failed"
    if [ "$failed" = 0 ]; then
        durable_barrier || failed=1
    fi
    if [ "$failed" = 0 ]; then
        durable_set_state "$INTEGRATION_TX_DIR/state" ROLLED_BACK || failed=1
    fi
    if [ "$failed" = 0 ]; then
        INTEGRATION_ACTIVE=0
        return 0
    fi
    return 1
}

restore_parallel_units_after_rewrite() {
    local base snap rel unit q entry service state enabled list
    local -a roots=()
    base="$INTEGRATION_TX_DIR/snapshot"
    q="$INTEGRATION_TX_DIR/post-rewrite-overwritten"
    list="$INTEGRATION_TX_DIR/snapshot-units.list0"
    : >"$list"
    [ -d "$base/etc/systemd/system" ] && roots+=("$base/etc/systemd/system")
    [ -d "$base/usr/lib/systemd/system" ] && roots+=("$base/usr/lib/systemd/system")
    if [ "${#roots[@]}" -gt 0 ]; then
        find "${roots[@]}" \( -type f -o -type l \) \
            \( -name 'php-fpm*.service' -o -path '*/php-fpm*.service.d/*' \) \
            -print0 >"$list" 2>/dev/null || return 1
    fi
    while IFS= read -r -d '' snap; do
        [ -f "$snap" ] || [ -L "$snap" ] || continue
        rel=${snap#"$base"/}; unit="/$rel"
        mkdir -p "$q/$(dirname "$rel")" "$(dirname "$unit")"
        if [ -e "$unit" ] || [ -L "$unit" ]; then mv "$unit" "$q/$rel" || return 1; fi
        cp -a "$snap" "$unit" || return 1
        log "Khôi phục unit $(basename "$unit") sau CustomBuild rewrite"
    done <"$list"
    systemctl daemon-reload
    for entry in $INTEGRATION_SERVICE_STATES; do
        IFS=: read -r service state enabled <<<"$entry"
        case "$service:$state" in
            php-fpm*:active)
                systemctl is-active --quiet "$service" 2>/dev/null || systemctl start "$service"
                ;;
            php-fpm*:*)
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    systemctl stop "$service" || return 1
                fi
                ;;
        esac
        case "$service:$enabled" in
            php-fpm*:enabled) systemctl enable "$service" >/dev/null 2>&1 || return 1 ;;
            php-fpm*:disabled) systemctl disable "$service" >/dev/null 2>&1 || return 1 ;;
            php-fpm*:masked) systemctl mask "$service" >/dev/null 2>&1 || return 1 ;;
            php-fpm*:static|php-fpm*:indirect|php-fpm*:generated|php-fpm*:not-found) ;;
        esac
    done
}

restore_parallel_configs_after_rewrite() {  # target suffix
    local target_s=$1 base snap rel dest dest_s q tmp status
    base="$INTEGRATION_TX_DIR/snapshot"
    q="$INTEGRATION_TX_DIR/post-rewrite-overwritten"
    for snap in "$base"/usr/local/php*/etc/php-fpm.conf; do
        [ -f "$snap" ] || continue
        rel=${snap#"$base"/}; dest="/$rel"
        dest_s=${dest#/usr/local/php}; dest_s=${dest_s%%/*}
        [ "$dest_s" = "$target_s" ] && continue
        mkdir -p "$q/$(dirname "$rel")" "$(dirname "$dest")"
        if [ -e "$dest" ] || [ -L "$dest" ]; then mv "$dest" "$q/$rel" || return 1; fi
        cp -a "$snap" "$dest" || return 1
        record_change "restore-parallel-fpm-config" "$dest"
    done

    status=/usr/local/directadmin/data/admin/services.status
    snap="$base/${status#/}"
    if [ -f "$snap" ]; then
        tmp="$INTEGRATION_TX_DIR/services.status.merged"
        cp -a "$snap" "$tmp" || return 1
        set_kv "$tmp" "php-fpm$target_s" ON || return 1
        mkdir -p "$q/$(dirname "${status#/}")"
        if [ -e "$status" ] || [ -L "$status" ]; then mv "$status" "$q/${status#/}" || return 1; fi
        cp -a "$tmp" "$status" || return 1
        record_change "restore-services-status" "preserved prior entries; php-fpm$target_s=ON"
    fi
}

ensure_custombuild_branch_support() {  # branch
    local v=$1 s=${1/./} P=$PHP_PREFIX_ROOT/php${1/./}
    local build="$DA_CB/build" line count tmp template_src template_dst custom_versions metadata
    line=$(grep -m1 '^PHP1_RELEASE_SET=' "$build" 2>/dev/null || true)
    [ -n "$line" ] || die "Không tìm thấy PHP1_RELEASE_SET trong $build"
    if ! grep -Fqw "$v" <<<"$line"; then
        case "$v" in 8.2|8.3|8.4|8.5) ;; *) die "Không có backport metadata cho PHP $v." ;; esac
        grep -Fqw 8.0 <<<"$line" || die "CustomBuild quá cũ/khác cấu trúc; thiếu mốc PHP 8.0 để backport an toàn PHP $v."
        [ -f "$build" ] && [ ! -L "$build" ] || die "$build phải là regular file, không phải symlink."
        count=$(grep -c '^PHP1_RELEASE_SET=' "$build")
        [ "$count" -eq 1 ] || die "PHP1_RELEASE_SET xuất hiện $count lần; từ chối vá mơ hồ."
        tmp="$build.dabuild.$$"
        awk -v target="$v" '
            /^PHP1_RELEASE_SET="/ {
                if ($0 !~ /"$/) exit 41
                sub(/"$/, " " target "\"")
                changed=1
            }
            {print}
            END {if (!changed) exit 42}
        ' "$build" >"$tmp" || { mv "$tmp" "$INTEGRATION_TX_DIR/failed-custombuild-build" 2>/dev/null || true; die "Không vá được PHP1_RELEASE_SET"; }
        chmod --reference="$build" "$tmp"
        chown --reference="$build" "$tmp"
        if command -v chcon >/dev/null 2>&1; then chcon --reference="$build" "$tmp" 2>/dev/null || true; fi
        bash -n "$tmp" || { mv "$tmp" "$INTEGRATION_TX_DIR/failed-custombuild-build"; die "CustomBuild lỗi cú pháp sau backport PHP $v"; }
        mv -f "$tmp" "$build"
        grep -m1 '^PHP1_RELEASE_SET=' "$build" | grep -Fqw "$v" || die "Backport PHP $v không được ghi nhận"
        record_change "custombuild-php-compat" "branch=$v patched=$build transaction=$INTEGRATION_TX_DIR"
        log "Đã thêm compatibility metadata PHP $v vào CustomBuild cũ"
    fi

    custom_versions="$DA_CB/custom_versions.txt"
    metadata="php$s:${PHPV[$v]}:${PHPMD5[$v]}"
    if [ -e "$custom_versions" ] || [ -L "$custom_versions" ]; then
        [ -f "$custom_versions" ] && [ ! -L "$custom_versions" ] \
            || die "custom_versions.txt phải là regular file: $custom_versions"
    fi
    if ! grep -Fxq "$metadata" "$custom_versions" 2>/dev/null; then
        tmp="$custom_versions.dabuild.$$"
        if [ -f "$custom_versions" ]; then
            awk -F: -v key="php$s" '$1 != key {print}' "$custom_versions" >"$tmp"
            chmod --reference="$custom_versions" "$tmp"
            chown --reference="$custom_versions" "$tmp"
        else
            : >"$tmp"
            chmod 0644 "$tmp"
            chown root:root "$tmp"
        fi
        printf '%s\n' "$metadata" >>"$tmp"
        mv -f "$tmp" "$custom_versions"
        record_change "custombuild-version-metadata" "branch=$v metadata=$metadata transaction=$INTEGRATION_TX_DIR"
        log "Đã ghim metadata source PHP ${PHPV[$v]} cho CustomBuild cũ"
    fi

    # fpmChecks() của CustomBuild cũ sẽ copy file này khi rewrite_confs.
    template_src="$P/etc/php-fpm.conf"
    template_dst="$DA_CB/custom/fpm/conf/php-fpm.conf.$s"
    [ -f "$template_src" ] || die "Thiếu FPM config nguồn để tạo CustomBuild template: $template_src"
    if [ -e "$template_dst" ] || [ -L "$template_dst" ]; then
        [ -f "$template_dst" ] && [ ! -L "$template_dst" ] || die "$template_dst phải là regular file"
        grep -Fq "php-fpm$s.conf" "$template_dst" \
            || die "Custom FPM template hiện có không include pool php-fpm$s.conf"
        ! grep -Eq '^[[:space:]]*\[webapps\][[:space:]]*$' "$template_dst" \
            || die "Custom FPM template $template_dst còn pool dùng chung [webapps]; từ chối dùng cho multi-user."
    else
        mkdir -p "$(dirname "$template_dst")"
        tmp="$template_dst.dabuild.$$"
        cat >"$tmp" <<EOF
; Managed by da-php-build.sh for DirectAdmin per-user pools only.
[global]
error_log = log/php-fpm.log
log_level = notice

; Every selected DirectAdmin account gets its own pool/socket.
include=/usr/local/directadmin/data/users/*/php/php-fpm$s.conf
EOF
        chmod 0644 "$tmp"; chown root:root "$tmp"
        mv -f "$tmp" "$template_dst"
        record_change "custombuild-fpm-template" "branch=$v installed=$template_dst transaction=$INTEGRATION_TX_DIR"
    fi
}

validate_root_owned_path_chain() {  # absolute directory
    local path=$1 current=/ part uid mode
    local -a _lock_parts=()
    [[ "$path" = /* ]] || die "Đường dẫn lock phải tuyệt đối: $path"
    IFS='/' read -r -a _lock_parts <<<"${path#/}"
    for part in "${_lock_parts[@]}"; do
        [ -n "$part" ] || continue
        current=${current%/}/$part
        [ -d "$current" ] && [ ! -L "$current" ] \
            || die "Thành phần đường dẫn lock không phải thư mục thật: $current"
        uid=$(stat -Lc '%u' "$current")
        mode=$(stat -Lc '%a' "$current")
        [ "$uid" -eq 0 ] || die "Thành phần đường dẫn lock không thuộc root: $current"
        (( (8#$mode & 0022) == 0 )) || die "Thành phần đường dẫn lock cho phép group/other ghi: $current ($mode)"
    done
}

acquire_integration_lock() {
    local lock="$PROJECT_HOME/runtime/directadmin-mutation.lock" path_inode fd_inode uid mode state
    [ -z "$INTEGRATION_LOCK_FD" ] || return 0
    mkdir -p "$PROJECT_HOME/runtime"
    validate_root_owned_path_chain "$PROJECT_HOME/runtime"
    if [ -e "$lock" ] || [ -L "$lock" ]; then
        [ -f "$lock" ] && [ ! -L "$lock" ] || die "Lock phải là regular file, không phải symlink: $lock"
    else
        ( umask 077; set -o noclobber; : >"$lock" ) 2>/dev/null \
            || { [ -f "$lock" ] && [ ! -L "$lock" ]; } \
            || die "Không tạo được lock an toàn: $lock"
    fi
    uid=$(stat -Lc '%u' "$lock"); mode=$(stat -Lc '%a' "$lock")
    [ "$uid" -eq 0 ] && [ "$mode" = 600 ] \
        || die "Lock phải thuộc root và mode 0600: $lock (uid=$uid mode=$mode)"
    path_inode=$(stat -Lc '%d:%i' "$lock")
    exec {INTEGRATION_LOCK_FD}<>"$lock"
    fd_inode=$(stat -Lc '%d:%i' "/proc/${BASHPID:-$$}/fd/$INTEGRATION_LOCK_FD")
    [ "$path_inode" = "$fd_inode" ] || die "Lock inode thay đổi khi mở: $lock"
    flock -n "$INTEGRATION_LOCK_FD" || die "Một transaction build/integration DirectAdmin khác đang chạy."
    [ "$(stat -Lc '%d:%i' "$lock")" = "$fd_inode" ] || die "Lock pathname bị thay sau flock: $lock"
    local unresolved_list="$PROJECT_HOME/runtime/unresolved-transactions.list0" state_file tx_dir
    : >"$unresolved_list"
    if [ "${DABUILD_RECOVERY:-0}" != 1 ] && [ -d "$WORK/transactions" ]; then
        find "$WORK/transactions" -type d -name 'run.*' -print0 >"$unresolved_list" 2>/dev/null \
            || die "Không kiểm tra được transaction cũ"
        while IFS= read -r -d '' tx_dir; do
            state_file="$tx_dir/state"
            [ -f "$state_file" ] && [ ! -L "$state_file" ] \
                || die "Transaction thiếu state hợp lệ: $tx_dir"
            state=$(tr -d '\n' <"$state_file" 2>/dev/null || true)
            case "$state" in
                COMMITTED|ROLLED_BACK|TEST_CLOSED) ;;
                *) die "Có transaction chưa kết thúc sau crash/SIGKILL: $tx_dir (state=${state:-missing}). Cần kiểm tra và rollback trước khi chạy tiếp." ;;
            esac
        done <"$unresolved_list"
    fi
}

pool_value() {  # file section key
    awk -v wanted_section="$2" -v wanted_key="$3" '
        function trim(value) {
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        {
            line=trim($0)
            if (line ~ /^\[[^]]+\]$/) {
                section=substr(line, 2, length(line)-2)
                next
            }
            if (section != wanted_section) next
            pos=index(line, "=")
            if (!pos) next
            key=trim(substr(line, 1, pos-1))
            if (key != wanted_key) next
            print trim(substr(line, pos+1))
            exit
        }
    ' "$1"
}

validate_no_shared_pool_effective() {  # master-config per-user-glob
    local master=$1 include_glob=$2 f
    ! grep -Eq '^[[:space:]]*\[webapps\][[:space:]]*$|webapps\.sock' "$master" || return 1
    for f in $include_glob; do
        [ -f "$f" ] || continue
        ! grep -Eq '^[[:space:]]*\[webapps\][[:space:]]*$|webapps\.sock' "$f" || return 1
    done
}

effective_output_has_shared_pool() {
    grep -Eq '(^|[[:space:]])\[webapps\][[:space:]]*$|webapps\.sock'
}

socket_listener_exact() {  # exact-socket-path; ss listing on stdin
    awk -v wanted="$1" '
        { for (i=1; i<=NF; i++) if ($i == wanted) found=1 }
        END { exit !found }
    '
}

vhost_domain_maps_socket() {  # apache|nginx file domain socket
    local mode=$1 file=$2 domain=$3 socket=$4
    awk -v mode="$mode" -v wanted_domain="$domain" -v wanted_socket="$socket" '
        function exact_path(line, path, p, nextc, prevc) {
            p=index(line, path)
            while (p) {
                prevc=(p == 1 ? "" : substr(line, p-1, 1))
                nextc=substr(line, p+length(path), 1)
                if ((prevc == "" || prevc ~ /[:=([|;[:space:]"\047]/) && \
                    (nextc == "" || nextc ~ /[|;[:space:]"\047)]/)) return 1
                line=substr(line, p+1)
                p=index(line, path)
            }
            return 0
        }
        function domain_line(line, n, token, i) {
            gsub(/[;"\047]/, " ", line)
            n=split(line, token, /[[:space:]]+/)
            for (i=1; i<=n; i++) if (tolower(token[i]) == tolower(wanted_domain)) return 1
            return 0
        }
        function finish_block() {
            if (has_domain && has_socket) found=1
            has_domain=0; has_socket=0
        }
        mode == "apache" {
            directive=$0; sub(/[[:space:]]*#.*/, "", directive)
            if (directive ~ /^[[:space:]]*<VirtualHost([[:space:]>]|$)/) { in_block=1; has_domain=0; has_socket=0 }
            if (in_block && directive ~ /^[[:space:]]*Server(Name|Alias)[[:space:]]+/ && domain_line(directive)) has_domain=1
            if (in_block && exact_path(directive, wanted_socket)) has_socket=1
            if (in_block && directive ~ /^[[:space:]]*<\/VirtualHost>[[:space:]]*$/) { finish_block(); in_block=0 }
            next
        }
        mode == "nginx" {
            directive=$0; sub(/[[:space:]]*#.*/, "", directive)
            if (!in_block && directive ~ /^[[:space:]]*server[[:space:]]*\{/) { in_block=1; depth=0; has_domain=0; has_socket=0 }
            if (in_block) {
                line=directive; opens=gsub(/\{/, "{", line); closes=gsub(/\}/, "}", line); depth+=opens-closes
                if (directive ~ /^[[:space:]]*server_name[[:space:]]+/ && domain_line(directive)) has_domain=1
                if (exact_path(directive, wanted_socket)) has_socket=1
                if (depth <= 0) { finish_block(); in_block=0 }
            }
            next
        }
        END { exit !found }
    ' "$file"
}

set_domain_slot() {  # file slot
    local file=$1 slot=$2 tmp="$1.dabuild.$$"
    awk -F= -v slot="$slot" '
        BEGIN {done=0}
        $1 == "php1_select" {print "php1_select=" slot; done=1; next}
        {print}
        END {if (!done) print "php1_select=" slot}
    ' "$file" >"$tmp"
    chmod --reference="$file" "$tmp"
    chown --reference="$file" "$tmp"
    mv -f "$tmp" "$file"
}

verify_domain_php_runtime() {  # user domain suffix expected-version
    local user=$1 domain=$2 s=$3 expected=$4 docroot probe output uid evidence
    docroot="/home/$user/domains/$domain/public_html"
    [ -d "$docroot" ] || die "Không thấy document root chuẩn của $domain: $docroot"
    probe="$docroot/dabuild-check-$s-$$-${RANDOM}.php"
    [ ! -e "$probe" ] && [ ! -L "$probe" ] || die "Probe path đã tồn tại: $probe"
    scope_backup "$probe"
    printf '%s\n' "<?php echo PHP_VERSION, '|', PHP_SAPI, '|', (function_exists('posix_geteuid') ? posix_geteuid() : -1);" >"$probe"
    chmod 0644 "$probe"
    chown --reference="$docroot" "$probe"
    uid=$(id -u "$user")
    if ! output=$(curl -kfsS --resolve "$domain:443:127.0.0.1" --max-time 20 "https://$domain/$(basename "$probe")"); then
        evidence="$INTEGRATION_TX_DIR/http-probes/failed-$user-$domain.php"
        mkdir -p "$(dirname "$evidence")"; mv "$probe" "$evidence" 2>/dev/null || true
        die "Origin HTTPS/PHP probe của $domain thất bại"
    fi
    evidence="$INTEGRATION_TX_DIR/http-probes/passed-$user-$domain.php"
    mkdir -p "$(dirname "$evidence")"; mv "$probe" "$evidence" || die "Không thu hồi được PHP probe khỏi webroot"
    [ "$output" = "$expected|fpm-fcgi|$uid" ] \
        || die "PHP probe $domain trả '$output', cần '$expected|fpm-fcgi|$uid'"
    record_change "request-proof-php$s" "user=$user domain=$domain result=$output"
}

integrate_fpm() {  # branch slot USER DOMAIN [USER DOMAIN ...]
    local v=${1:-} slot=${2:-}
    shift 2 2>/dev/null || true
    local s P old_release old_mode svc webserver old_fpm_state service state enabled load_state user domain domain_conf pool user_httpd unit f selected pair
    local expected_group value socket_path socket_owner socket_group socket_mode fpm_test_output
    local -a users=() domains=() affected=()
    local -A state_seen=()
    local -A requested=()
    [ -n "${PHPV[$v]:-}" ] || die "Dùng: $0 integrate 8.5 4 USER DOMAIN [USER DOMAIN ...]"
    case "$slot" in 2|3|4) ;; *) die "Chỉ được dùng slot phụ 2, 3 hoặc 4; không tự thay PHP chính." ;; esac
    [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || die "Cần truyền từng cặp USER DOMAIN."
    prepare_dirs
    acquire_integration_lock
    while [ "$#" -gt 0 ]; do
        user=$1; domain=$2; shift 2
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || die "User DirectAdmin không hợp lệ: $user"
        [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || die "Domain không hợp lệ: $domain"
        domain_conf="/usr/local/directadmin/data/users/$user/domains/$domain.conf"
        [ -f "$domain_conf" ] || die "Không thấy cấu hình domain: $domain_conf"
        users+=("$user"); domains+=("$domain")
        requested["$user/$domain"]=1
    done
    [ -x "$DA_CB/build" ] || die "Không thấy $DA_CB/build"
    [ -r "$DA_OPTIONS" ] || die "Không đọc được $DA_OPTIONS"
    s=${v/./}; P=/usr/local/php$s; svc=php-fpm$s
    [ -x "$P/bin/php$s" ] || [ -x "$P/bin/php" ] || die "Chưa có runtime PHP $v tại $P"
    old_release=$(get_da_option "php${slot}_release")
    old_mode=$(get_da_option "php${slot}_mode")
    if [ "$old_release" != "$v" ] || [ "$old_mode" != php-fpm ]; then
        for f in /usr/local/directadmin/data/users/*/domains/*.conf; do
            [ -f "$f" ] || continue
            selected=$(kv_get "$f" php1_select)
            [ "$selected" = "$slot" ] || continue
            user=${f#/usr/local/directadmin/data/users/}; user=${user%%/*}
            domain=$(basename "$f" .conf)
            affected+=("$user/$domain")
        done
        [ "$FORCE_SLOT" = 1 ] \
            || die "php$slot đang là PHP $old_release mode ${old_mode:-unknown}; domain ảnh hưởng: ${affected[*]:-(không có)}. Cần FORCE_SLOT=1."
        for pair in "${affected[@]+"${affected[@]}"}"; do
            [ -n "${requested[$pair]:-}" ] \
                || die "Từ chối đổi slot $slot: domain $pair đang dùng PHP $old_release/${old_mode:-unknown} nhưng không có trong danh sách xác nhận."
        done
    fi
    webserver=$(get_da_option webserver)
    case "$webserver" in apache|nginx|nginx_apache) ;; *) die "Lệnh integrate hiện chỉ hỗ trợ PHP-FPM với apache/nginx/nginx_apache; đang là $webserver" ;; esac
    WEBSERVER=$webserver
    detect_web_group
    expected_group=$WEB_GROUP
    prepare_dirs
    backup_integration_scope "$s"
    old_fpm_state=$(systemctl is-active "$svc" 2>/dev/null || true)
    INTEGRATION_SERVICE_STATES=""
    : >"$INTEGRATION_TX_DIR/services.tsv"
    for unit in /etc/systemd/system/php-fpm*.service /usr/lib/systemd/system/php-fpm*.service; do
        [ -e "$unit" ] || [ -L "$unit" ] || continue
        service=$(basename "$unit" .service)
        state_seen[$service]=1
    done
    for service in php-fpm82 php-fpm83 php-fpm84 php-fpm85 "$svc" httpd nginx directadmin; do
        state_seen[$service]=1
    done
    for service in "${!state_seen[@]}"; do
        load_state=$(systemctl_property "$service" LoadState) \
            || die "Không đọc được LoadState chính xác của $service"
        if [ "$load_state" = not-found ]; then
            state=not-found
            enabled=not-found
        else
            [ "$load_state" = loaded ] \
                || die "LoadState $service không an toàn để transaction: $load_state"
            state=$(systemctl_property "$service" ActiveState) \
                || die "Không đọc được ActiveState chính xác của $service"
            enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
            case "$state" in active|inactive) ;; *) die "Trạng thái $service không an toàn để transaction: $state" ;; esac
            case "$enabled" in enabled|disabled|masked|static|indirect|generated) ;;
                *) die "Trạng thái enable của $service không hỗ trợ rollback chính xác: $enabled" ;;
            esac
        fi
        INTEGRATION_SERVICE_STATES="$INTEGRATION_SERVICE_STATES $service:$state:$enabled"
        printf '%s\t%s\t%s\n' "$service" "$state" "$enabled" >>"$INTEGRATION_TX_DIR/services.tsv"
    done
    arm_integration_mutation
    record_change "integrate-php$s" "planned slot=$slot domains=${domains[*]} old_release=$old_release old_fpm_state=$old_fpm_state transaction=$INTEGRATION_TX_DIR"

    ensure_custombuild_branch_support "$v"
    run "đặt php${slot}_release=$v" "$DA_CB/build" set "php${slot}_release" "$v"
    run "đặt php${slot}_mode=php-fpm" "$DA_CB/build" set "php${slot}_mode" php-fpm
    local i
    for i in "${!users[@]}"; do
        set_domain_slot "/usr/local/directadmin/data/users/${users[$i]}/domains/${domains[$i]}.conf" "$slot"
    done
    run_rewrite_confs_transactional
    restore_parallel_units_after_rewrite || die "Không khôi phục được systemd unit PHP-FPM sau rewrite_confs"
    restore_parallel_configs_after_rewrite "$s" || die "Không khôi phục được cấu hình PHP-FPM song song sau rewrite_confs"

    [ "$(get_da_option "php${slot}_release")" = "$v" ] || die "php${slot}_release không còn là $v sau rewrite"
    [ "$(get_da_option "php${slot}_mode")" = php-fpm ] || die "php${slot}_mode không còn là php-fpm sau rewrite"
    grep -m1 '^PHP1_RELEASE_SET=' "$DA_CB/build" | grep -Fqw "$v" || die "Compatibility PHP $v bị mất sau rewrite"
    grep -Fqx "php$s:${PHPV[$v]}:${PHPMD5[$v]}" "$DA_CB/custom_versions.txt" || die "Metadata php$s bị mất sau rewrite"
    grep -Fq "include=/usr/local/directadmin/data/users/*/php/php-fpm$s.conf" "$DA_CB/custom/fpm/conf/php-fpm.conf.$s" \
        || die "Custom FPM template PHP $v bị sai"
    for i in "${!users[@]}"; do
        [ "$(kv_get "/usr/local/directadmin/data/users/${users[$i]}/domains/${domains[$i]}.conf" php1_select)" = "$slot" ] \
            || die "Selector ${domains[$i]} không bền sau rewrite"
    done

    grep -Fq "include=/usr/local/directadmin/data/users/*/php/php-fpm$s.conf" "$P/etc/php-fpm.conf" \
        || die "FPM config đang chạy không include per-user pool PHP $v"
    validate_no_shared_pool_effective "$P/etc/php-fpm.conf" \
        "/usr/local/directadmin/data/users/*/php/php-fpm$s.conf" \
        || die "FPM effective config còn shared webapps pool/socket; từ chối multi-user integration"
    fpm_test_output=$("$P/sbin/php-fpm$s" -tt 2>&1) || die "php-fpm$s -tt thất bại: $fpm_test_output"
    ! printf '%s\n' "$fpm_test_output" | effective_output_has_shared_pool \
        || die "php-fpm$s -tt phát hiện shared webapps pool/socket"
    case "$webserver" in
        apache) apachectl configtest >/dev/null 2>&1 || die "Apache configtest thất bại" ;;
        nginx) nginx -t >/dev/null 2>&1 || die "Nginx configtest thất bại" ;;
        nginx_apache)
            apachectl configtest >/dev/null 2>&1 || die "Apache configtest thất bại"
            nginx -t >/dev/null 2>&1 || die "Nginx configtest thất bại"
            ;;
    esac
    systemctl enable "$svc" || die "Enable $svc thất bại"
    [ "$(systemctl is-enabled "$svc" 2>/dev/null || true)" = enabled ] \
        || die "$svc chưa enabled sau tích hợp"
    systemctl restart "$svc" || die "Restart $svc thất bại"
    systemctl is-active --quiet "$svc" || die "$svc không active sau restart"
    for i in "${!users[@]}"; do
        user=${users[$i]}; domain=${domains[$i]}
        pool="/usr/local/directadmin/data/users/$user/php/php-fpm$s.conf"
        [ -s "$pool" ] || die "DirectAdmin không sinh pool $pool; transaction rollback: $INTEGRATION_TX_DIR"
        grep -Fqx "[$user]" "$pool" || die "Pool $pool không có section riêng [$user]"
        value=$(pool_value "$pool" "$user" listen)
        case "$value" in "/usr/local/php$s/sockets/$user.sock"|"/usr/local/php$s/sockets/\$pool.sock") ;;
            *) die "Pool $pool không trỏ đúng PHP $v: ${value:-missing}" ;;
        esac
        value=$(pool_value "$pool" "$user" user)
        case "$value" in "$user"|'$pool') ;; *) die "Pool $pool có user không đúng account: ${value:-missing}" ;; esac
        value=$(pool_value "$pool" "$user" group)
        case "$value" in "$user"|'$pool') ;; *) die "Pool $pool có group không đúng account: ${value:-missing}" ;; esac
        value=$(pool_value "$pool" "$user" listen.owner)
        case "$value" in "$user"|'$pool') ;; *) die "Pool $pool có listen.owner không đúng account: ${value:-missing}" ;; esac
        [ "$(pool_value "$pool" "$user" listen.group)" = "$expected_group" ] \
            || die "Pool $pool có listen.group sai; cần $expected_group"
        value=$(pool_value "$pool" "$user" listen.mode)
        case "$value" in 660|0660) ;; *) die "Pool $pool có listen.mode không an toàn: ${value:-missing}" ;; esac
        socket_path="/usr/local/php$s/sockets/$user.sock"
        case "$webserver" in
            apache|nginx_apache)
                user_httpd="/usr/local/directadmin/data/users/$user/httpd.conf"
                vhost_domain_maps_socket apache "$user_httpd" "$domain" "$socket_path" \
                    || die "Vhost Apache $domain chưa trỏ chính xác tới socket PHP $v"
                ;;
            nginx)
                user_httpd="/usr/local/directadmin/data/users/$user/nginx.conf"
                vhost_domain_maps_socket nginx "$user_httpd" "$domain" "$socket_path" \
                    || die "Vhost Nginx $domain chưa trỏ chính xác tới socket PHP $v"
                ;;
        esac
        ss -xl 2>/dev/null | socket_listener_exact "$socket_path" \
            || die "Không thấy listener chính xác $socket_path"
        [ -S "$socket_path" ] || die "Socket path không phải Unix socket: $socket_path"
        socket_owner=$(stat -Lc '%U' "$socket_path")
        socket_group=$(stat -Lc '%G' "$socket_path")
        socket_mode=$(stat -Lc '%a' "$socket_path")
        [ "$socket_owner" = "$user" ] || die "Socket $socket_path owner=$socket_owner, cần $user"
        [ "$socket_group" = "$expected_group" ] || die "Socket $socket_path group=$socket_group, cần $expected_group"
        [ "$socket_mode" = 660 ] || die "Socket $socket_path mode=$socket_mode, cần 660"
        verify_domain_php_runtime "$user" "$domain" "$s" "${PHPV[$v]}"
        record_change "integrate-php$s" "verified slot=$slot user=$user domain=$domain pool=$pool service=active request-php=${PHPV[$v]}"
    done
    finish_integration_mutation
    durable_barrier || die "Không flush được integration trước commit"
    durable_set_state "$INTEGRATION_TX_DIR/state" COMMITTED || die "Không ghi durable integration commit"
    INTEGRATION_ACTIVE=0
    log "DirectAdmin integration PHP $v: OK (slot $slot, ${#domains[@]} domain)"
}

recover_transaction() {  # transaction-directory
    local tx=${1:-} resolved root service state enabled
    [ -n "$tx" ] || die "Dùng: $0 recover TRANSACTION_DIRECTORY"
    [ -d "$tx" ] && [ ! -L "$tx" ] || die "Transaction directory không hợp lệ: $tx"
    resolved=$(readlink -f "$tx")
    root=$(readlink -f "$WORK/transactions")
    case "$resolved" in "$root"/*) ;; *) die "Transaction nằm ngoài $root: $resolved" ;; esac
    [ -f "$resolved/state" ] && [ ! -L "$resolved/state" ] || die "Thiếu state hợp lệ: $resolved/state"
    state=$(tr -d '\n' <"$resolved/state")
    case "$state" in COMMITTED|ROLLED_BACK) die "Transaction đã kết thúc: $state" ;; esac
    DABUILD_RECOVERY=1 acquire_integration_lock
    case "$resolved:$state" in
        */transactions/extensions/*:PREPARED|*/transactions/integration/*:PREPARED)
            durable_barrier || die "Không flush được PREPARED recovery"
            durable_set_state "$resolved/state" ROLLED_BACK || die "Không đóng được PREPARED transaction"
            log "Recovery PREPARED transaction hoàn tất, không có canonical mutation: $resolved"
            return 0
            ;;
    esac
    case "$resolved" in
        */transactions/integration/*)
            INTEGRATION_TX_DIR=$resolved
            INTEGRATION_SCOPE_LIST="$resolved/files.tsv"
            INTEGRATION_PRE_REWRITE_LIST="$resolved/pre-rewrite-paths.list0"
            INTEGRATION_SERVICE_STATES=""
            if [ -f "$resolved/services.tsv" ]; then
                while IFS=$'\t' read -r service state enabled; do
                    [ -n "$service" ] || continue
                    INTEGRATION_SERVICE_STATES="$INTEGRATION_SERVICE_STATES $service:$state:$enabled"
                done <"$resolved/services.tsv"
            fi
            INTEGRATION_ACTIVE=1
            rollback_integration || die "Recovery integration chưa hoàn tất: $resolved"
            ;;
        */transactions/extensions/*)
            EXTENSION_TX_DIR=$resolved
            EXTENSION_SCOPE_LIST="$resolved/files.tsv"
            EXTENSION_BRANCH=$(tr -d '\n' <"$resolved/branch")
            EXTENSION_ACTIVE=1
            rollback_extension || die "Recovery extension chưa hoàn tất: $resolved"
            ;;
        */transactions/runtime/*)
            RUNTIME_TX_DIR=$resolved
            RUNTIME_PREFIX=$(tr -d '\n' <"$resolved/runtime-prefix")
            RUNTIME_SERVICE=$(tr -d '\n' <"$resolved/runtime-service")
            RUNTIME_UNIT=$(tr -d '\n' <"$resolved/runtime-unit")
            RUNTIME_ACTIVE=1
            rollback_runtime || die "Recovery runtime chưa hoàn tất: $resolved"
            ;;
        *) die "Không nhận diện được loại transaction: $resolved" ;;
    esac
    log "Recovery transaction hoàn tất: $resolved"
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
    [ -n "$file" ] || die "Dùng: $0 unpack FILE.tar.gz"
    die "Lệnh unpack bị khóa fail-closed: giải nén archive trực tiếp vào / không đáp ứng transaction và kiểm tra archive an toàn. Hãy build bằng lệnh php hoặc triển khai qua quy trình staging đã kiểm duyệt."
}

usage() { awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"; }

main() {
    local cmd=${1:-help}; shift || true
    case "$cmd" in
        check)  preflight; toolchain; resolve_mode ;;
        detect) resolve_mode ;;
        fetch)  prepare_dirs; acquire_integration_lock; fetch_cmd "$@" ;;
        setup)  prepare_dirs; acquire_integration_lock; setup_pkgs ;;
        deps)   preflight; prepare_dirs; acquire_integration_lock; deps ;;
        php)
            [ "$#" -gt 0 ] || die "Dùng: $0 php 8.4 | php 8.2 8.3 8.4 8.5 | php all"
            [ "$1" != all ] || set -- $BRANCHES
            preflight; prepare_dirs; acquire_integration_lock; resolve_mode; deps
            local v; for v in "$@"; do build_php "$v"; done
            log "Hoàn tất runtime. Để website dùng PHP mới, chạy lệnh integrate với slot phụ + user + domain." ;;
        extensions) extensions_cmd "$@" ;;
        integrate) preflight; integrate_fpm "$@" ;;
        recover) prepare_dirs; recover_transaction "$@" ;;
        pack)   prepare_dirs; acquire_integration_lock; pack ;;
        unpack) prepare_dirs; acquire_integration_lock; unpack "$@" ;;
        *)      usage ;;
    esac
}
if [ "${DABUILD_SOURCE_ONLY:-0}" != 1 ]; then
    main "$@"
fi
