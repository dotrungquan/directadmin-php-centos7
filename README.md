# da-php-build

Script bash build **PHP 8.2 / 8.3 / 8.4 / 8.5 từ source** trên **CentOS 7 + DirectAdmin cũ**, chạy song song với PHP đang dùng mà không đụng vào CustomBuild.

CentOS 7 chỉ có ICU 50 và GCC 4.8.5, không đủ cho PHP 8.4 và 8.5 (cần ICU ≥ 57.1). Script build một bộ thư viện riêng vào `/opt/dabuild` (OpenSSL 1.1.1, ICU 57, libxml2, curl, ...), rồi build từng bản PHP vào `/usr/local/phpXX` theo layout của DirectAdmin/CustomBuild.

## Tính năng

- Build PHP 8.2, 8.3, 8.4, 8.5 vào `/usr/local/php82` ... `/usr/local/php85`, mỗi bản độc lập.
- **Tự nhận diện webserver** từ `options.conf` của CustomBuild để build đúng kiểu: PHP-FPM hoặc lsphp.
- Dependency chỉ build **một lần**, các bản PHP dùng chung.
- Source được ghim phiên bản và **kiểm sha256** trước khi dùng.
- Tải source có nhiều nguồn, hỗ trợ proxy/mirror, và có lệnh `fetch` để tải sẵn trên máy khác.
- Tự vá GCC 4.8 cho PHP 8.4 và 8.5 (hoặc dùng `TOOLCHAIN=scl` với devtoolset).
- Đóng gói (`pack`) và triển khai (`unpack`) sang server khác.
- Không chạy `rewrite_confs`, không đổi PHP chính của DirectAdmin.

## Phiên bản được ghim

| Nhánh | Bản PHP |
|---|---|
| 8.2 | 8.2.35 |
| 8.3 | 8.3.36 |
| 8.4 | 8.4.27 |
| 8.5 | 8.5.12 |

Dependency: OpenSSL 1.1.1w, ICU 57.1, libxml2 2.9.14, curl 7.88.1, zlib 1.3.1, GMP 6.2.1, Oniguruma 6.9.9, libzip 1.2.0, SQLite 3.45.3.

## Yêu cầu

- CentOS 7, x86_64, chạy bằng root (đặt `DABUILD_SKIP_OS=1` để bỏ qua kiểm tra OS).
- Tối thiểu khoảng 8 GB trống tại thư mục `WORK` (mặc định `/var/tmp/dabuild`).
- Các gói build: chạy `./da-php-build.sh setup` để `yum install` những gói còn thiếu.
- Nên có `libsodium-devel` (từ EPEL) nếu muốn extension sodium.
- Truy cập được tới nguồn tải source, hoặc chép tay source vào `SRC` (xem phần *Xử lý lỗi tải*).

## Bắt đầu nhanh

```bash
git clone <repo-url> && cd <repo>
chmod +x da-php-build.sh

./da-php-build.sh check            # kiểm tra máy, cho biết sẽ build kiểu nào (không đổi gì)
./da-php-build.sh setup            # yum install gói build còn thiếu
./da-php-build.sh php 8.4          # build 1 bản (tự build dependency nếu chưa có)
./da-php-build.sh php 8.2 8.3 8.4 8.5   # hoặc: php all
```

Build lâu, nên chạy trong `screen`/`tmux`, hoặc:

```bash
nohup ./da-php-build.sh php all > run.log 2>&1 &
```

Log chi tiết nằm ở `/root/dabuild-logs/`.

## Các lệnh

| Lệnh | Tác dụng |
|---|---|
| `check` | Kiểm tra máy và in chế độ build sẽ dùng. Không thay đổi gì. |
| `detect` | Chỉ in webserver và chế độ build (`fpm` / `lsphp` / `both`). |
| `fetch [deps\|all\|8.x ...]` | Chỉ tải và kiểm sha256 source, không build. Không tham số = `all`. |
| `setup` | `yum install` các gói build còn thiếu. |
| `deps` | Build dependency vào `/opt/dabuild` (làm một lần). |
| `php 8.x [8.y ...]` | Build một hoặc nhiều bản PHP. `php all` = cả 4 bản. |
| `pack` | Đóng tar (dependency + các bản PHP đã build) để mang sang server khác. |
| `unpack FILE.tar.gz` | Giải nén trên server đích và đăng ký systemd. |

## Tự nhận diện webserver

Script đọc `webserver=` trong `/usr/local/directadmin/custombuild/options.conf`:

| `webserver=` | Chế độ build | Kết quả |
|---|---|---|
| `apache`, `nginx`, `nginx_apache` | `fpm` | `php-fpmXX`, socket, unit systemd `php-fpmXX.service` |
| `openlitespeed`, `litespeed` | `lsphp` | `bin/lsphpXX`, không có service (OLS tự khởi chạy) |

Có thể ép tay bằng `MODE=fpm`, `MODE=lsphp` hoặc `MODE=both` (build cả hai SAPI trong một lần configure).

Nếu không có `options.conf`, script đoán theo phần mềm đã cài. Nếu `phpN_mode` trong CustomBuild lệch với webserver (ví dụ OLS nhưng `php-fpm`), script sẽ cảnh báo.

Với chế độ FPM, `listen.group` của pool được đọc từ `httpd.conf` (hoặc `nginx.conf` nếu chỉ chạy nginx). Ép bằng `WEB_GROUP=...` nếu cần.

## Biến môi trường

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `SRC` | `/usr/local/src/dabuild` | Thư mục chứa tarball source |
| `DEPS` | `/opt/dabuild` | Nơi cài dependency |
| `WORK` | `/var/tmp/dabuild` | Thư mục build tạm |
| `LOGS` | `/root/dabuild-logs` | Thư mục log |
| `OUT` | `/root/dabuild-pack` | Nơi `pack` đặt file tar |
| `JOBS` | min(số core, số GB RAM) | Số luồng `make` |
| `TOOLCHAIN` | `system` | `scl` để dùng devtoolset (GCC mới) |
| `MODE` | `auto` | `auto` / `fpm` / `lsphp` / `both` |
| `WEB_GROUP` | tự đọc | Group của webserver cho `listen.group` |
| `DA_OPTIONS` | đường dẫn `options.conf` | Nơi đọc cấu hình CustomBuild |
| `FORCE` | `0` | `1` = cho phép ghi đè `/usr/local/phpXX` không do script tạo |
| `RESTART` | `0` | fpm: enable + restart `php-fpmXX`; lsphp: kill `lsphpXX` để OLS khởi chạy lại |
| `EXTRA_CONFIGURE` | rỗng | Cờ configure thêm cho PHP |
| `CURL_OPTS` | rỗng | Cờ thêm cho curl, ví dụ `-x http://proxy:3128` |
| `PHP_MIRRORS` | rỗng | Mirror tải PHP thêm (cách nhau bằng dấu cách), được thử trước |

## Layout sau khi build

```
/usr/local/php85/
├── bin/php85, php, phpize85, php-config85, lsphp85*, lsphp*
├── sbin/php-fpm85, php-fpm**
├── etc/php-fpm.conf**
├── sockets/**            # socket của từng pool
├── lib/php.ini
├── lib/php.conf.d/       # file .ini nạp thêm (opcache, extension của bạn...)
└── .dabuild-managed      # dấu hiệu bản này do script tạo (kèm mode)
/etc/systemd/system/php-fpm85.service**

* chỉ có khi build lsphp     ** chỉ có khi build fpm
```

Pool FPM nạp cấu hình từng user của DirectAdmin qua `include=/usr/local/directadmin/data/users/*/php/php-fpmXX.conf`.

## Xử lý lỗi tải

Nếu máy không tới được `php.net` (firewall/route) thì script không tải được source. Có ba cách:

1. **Tải ở máy khác rồi chép sang** (nhanh nhất):

   ```bash
   SRC=./src ./da-php-build.sh fetch 8.2 8.3 8.4 8.5     # chạy trên máy có internet
   scp src/php-*.tar.gz root@server:/usr/local/src/dabuild/
   ```

   Script tự nhặt file nằm ở thư mục hiện tại, `/root`, `/tmp` hoặc `/usr/local/src` nếu sha256 khớp.
2. **Dùng proxy:** `CURL_OPTS='-x http://host:port' ./da-php-build.sh php 8.5`
3. **Dùng mirror:** `PHP_MIRRORS='https://mirror/php' ./da-php-build.sh php 8.5`

Kiểm tra mạng: `curl -4 -sI -m 10 https://www.php.net | head -1`.

Khi đã build xong dependency, script dùng curl 7.88 trong `/opt/dabuild` thay cho curl 7.29 của CentOS 7, nên lỗi `(35) incompatible or unsupported protocol version` ít gặp hơn.

## Cập nhật lên bản PHP mới

1. Sửa phiên bản trong mảng `PHPV` ở đầu script.
2. Cập nhật dòng sha256 tương ứng trong biến `SUMS`. Thiếu dòng này script chỉ cảnh báo, không kiểm được tính toàn vẹn.
3. Chạy lại, ví dụ `./da-php-build.sh php 8.4`.

Khi build lại, nếu `php-fpmXX` đang chạy thì script dừng nó ngay trước `make install` và restart sau khi xong.

> **Lưu ý:** mỗi lần build lại, script **ghi đè** `lib/php.ini`, `etc/php-fpm.conf` và `lib/php.conf.d/10-opcache.ini`. Đừng sửa tay `php.ini`. Hãy đặt cấu hình riêng vào file khác trong `lib/php.conf.d/`.

## Hạn chế và lưu ý

- **Redis, Imagick, ionCube chưa nằm trong script.** Đây là extension ngoài, cài thêm bằng PECL/phpize của đúng bản (`/usr/local/phpXX/bin/phpize`), hoặc nạp loader nhị phân của ionCube bằng `zend_extension`. Nên đặt file `.ini` trong `lib/php.conf.d/` để lần build lại không làm mất.
- **lsphp chưa kiểm chứng trên DirectAdmin + OpenLiteSpeed thật.** Cấu hình OLS do `build rewrite_confs` của DirectAdmin sinh ra và script không sửa nó. Bạn có thể cần trỏ extprocessor tới `/usr/local/phpXX/bin/lsphpXX`, và `rewrite_confs` có thể ghi đè chỉnh sửa tay.
- **PHP 8.5 trên GCC 4.8.5** chỉ được vá 2 header, nên `make` vẫn có thể lỗi. Nếu gặp, dùng `TOOLCHAIN=scl` với devtoolset (repo SCL của CentOS 7 nay nằm trên `vault.centos.org`).
- **Bảo mật:** CentOS 7 và OpenSSL 1.1.1 đã hết hỗ trợ, dependency được ghim sẽ không nhận bản vá. Chỉ dùng khi chưa thể nâng cấp hệ điều hành.
- Mỗi bản PHP có cả CLI. Script không đổi `php` mặc định của hệ thống.
- Phiên bản PHP 8.2 chỉ còn security support đến hết 2026.

## Gỡ một bản đã build

```bash
systemctl disable --now php-fpm85          # nếu là bản fpm
rm -f /etc/systemd/system/php-fpm85.service && systemctl daemon-reload
rm -rf /usr/local/php85
```

Thay `85` bằng bản cần gỡ. Thư mục `/opt/dabuild` dùng chung, chỉ xóa khi không còn bản PHP nào cần đến.

## Góp ý

Mở issue hoặc pull request nếu bạn gặp lỗi trên môi trường khác. Khi báo lỗi, hãy đính kèm file log trong `/root/dabuild-logs/` và kết quả của `./da-php-build.sh detect`.
