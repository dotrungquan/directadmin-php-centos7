# DirectAdmin Legacy PHP Builder

Script Bash build **PHP 8.2, 8.3, 8.4 và 8.5 từ source** trên **CentOS 7 + DirectAdmin 1.62.x**.

PHP được cài song song vào `/usr/local/phpXX`, không thay PHP chính của hệ thống. Dependency dùng chung được cài tại `/opt/dabuild`.

> [!CAUTION]
> ## LƯU Ý: BACKUP TRƯỚC KHI THỰC HIỆN
>
> Hãy tạo **snapshot VPS** hoặc bản backup có thể khôi phục trước khi build, rebuild hay tích hợp PHP.
>
> Script có transaction và rollback, nhưng vẫn thay đổi PHP runtime, systemd unit, CustomBuild, PHP-FPM và cấu hình webserver. Website đang sử dụng phiên bản PHP được rebuild có thể gián đoạn ngắn.

## Chức năng

- Build PHP `8.2.35`, `8.3.36`, `8.4.27`, `8.5.12`.
- Tự nhận diện Apache, Nginx, `nginx_apache`, LiteSpeed và OpenLiteSpeed.
- Build PHP-FPM, LSPHP hoặc cả hai.
- Build dependency riêng gồm OpenSSL 1.1.1w, ICU 57.1 và các thư viện cần thiết.
- Cài Redis `6.3.0` và Imagick `3.8.1` theo đúng PHP ABI.
- Kiểm tra SHA-256 của source trước khi build.
- Rebuild runtime bằng transaction và tự rollback nếu thất bại.
- Tích hợp PHP vào slot phụ của DirectAdmin 1.62.x.
- Tạo pool và socket PHP-FPM riêng cho từng user.
- Không tạo pool dùng chung `[webapps]` hoặc `webapps.sock`.
- Kiểm tra PHP, extension, FPM, socket, vhost và request thật sau integration.

## Yêu cầu

- CentOS 7 x86_64.
- DirectAdmin 1.62.x và CustomBuild 2.
- Quyền `root`.
- Khuyến nghị còn ít nhất 8 GB dung lượng trống.
- Nên chạy trong `screen` hoặc `tmux`.

## Cài đặt

```bash
mkdir -p /root/custom-da
cd /root/custom-da

curl -fsSL \
  -o da-php-build.sh \
  https://raw.githubusercontent.com/dotrungquan/directadmin-php-centos7/refs/heads/main/da-php-build.sh

chmod 750 da-php-build.sh
```

Hãy tải script xuống và kiểm tra trước khi chạy. Không dùng `curl ... | bash`.

## Hướng dẫn sử dụng

### 1. Kiểm tra server

```bash
cd /root/custom-da
./da-php-build.sh check
./da-php-build.sh detect
```

`check` và `detect` không build PHP.

### 2. Cài package build

```bash
./da-php-build.sh setup
```

### 3. Tải source trước nếu cần

```bash
./da-php-build.sh fetch all
```

Hoặc chỉ tải các phiên bản PHP:

```bash
./da-php-build.sh fetch 8.2 8.3 8.4 8.5
```

### 4. Build PHP

Build một phiên bản:

```bash
./da-php-build.sh php 8.2
```

Build toàn bộ:

```bash
./da-php-build.sh php all
```

Hoặc chỉ định nhiều phiên bản:

```bash
./da-php-build.sh php 8.2 8.3 8.4 8.5
```

Dependency được tự động build nếu `/opt/dabuild` chưa sẵn sàng. Redis và Imagick được cài mặc định.

### 5. Build lại PHP đã có

Nếu runtime có marker:

```text
/usr/local/phpXX/.dabuild-managed
```

chỉ cần chạy lại, không cần xóa runtime cũ:

```bash
./da-php-build.sh php 8.4
```

Nếu PHP được cài bởi CustomBuild hoặc công cụ khác và không có marker, cần cho phép script tiếp quản:

```bash
FORCE=1 ./da-php-build.sh php 8.2
```

Chỉ dùng `FORCE=1` sau khi đã backup và xác định các website đang sử dụng phiên bản PHP đó.

### 6. Build lại Redis và Imagick

```bash
./da-php-build.sh extensions 8.2
```

Hoặc:

```bash
./da-php-build.sh extensions 8.2 8.3 8.4 8.5
```

### 7. Tích hợp vào DirectAdmin

Cú pháp:

```bash
FORCE_SLOT=1 ./da-php-build.sh integrate PHP_VERSION SLOT USER DOMAIN
```

Ví dụ:

```bash
FORCE_SLOT=1 ./da-php-build.sh integrate \
  8.2 4 demo1 example.com
```

Sau integration:

```text
example.com
  → /usr/local/php82/sockets/demo1.sock
  → pool [demo1]
  → PHP worker chạy bằng UID demo1
```

Script sẽ kiểm tra domain owner, slot, pool, socket, quyền sở hữu, vhost, service và request PHP thật trước khi commit.

### 8. Khôi phục transaction bị gián đoạn

Dùng đúng đường dẫn transaction được script thông báo:

```bash
./da-php-build.sh recover /duong/dan/transaction/run.XXXXXX
```

Không tự xóa transaction chưa hoàn tất.

## Các lệnh chính

| Lệnh | Chức năng |
|---|---|
| `check` | Kiểm tra môi trường, không thay đổi hệ thống |
| `detect` | Hiển thị webserver và chế độ build |
| `fetch` | Tải và kiểm tra source |
| `setup` | Cài package build còn thiếu |
| `deps` | Build dependency vào `/opt/dabuild` |
| `php` | Build hoặc rebuild PHP |
| `extensions` | Build Redis và Imagick |
| `integrate` | Tích hợp PHP với DirectAdmin |
| `recover` | Khôi phục transaction bị gián đoạn |
| `pack` | Đóng gói runtime đã build; `unpack` hiện bị khóa an toàn |

## Biến thường dùng

```bash
MODE=fpm            # auto, fpm, lsphp hoặc both
JOBS=4              # số luồng make
FORCE=1             # tiếp quản runtime không do script tạo
FORCE_SLOT=1        # cho phép thay release/mode của slot
RESTART=1           # restart runtime khi có pool hợp lệ
INSTALL_EXTENSIONS=0 # không cài Redis và Imagick
```

Ví dụ ép chế độ PHP-FPM:

```bash
MODE=fpm ./da-php-build.sh php 8.2
```

## Kiểm tra sau khi build

Ví dụ PHP 8.2:

```bash
/usr/local/php82/bin/php -v
/usr/local/php82/bin/php -m | grep -E 'redis|imagick'
/usr/local/php82/sbin/php-fpm82 -t
systemctl status php-fpm82 --no-pager
```

PHP-FPM chưa có pool DirectAdmin sẽ được giữ inactive. Chạy `integrate` trước khi start service.

## Tác giả

**Đỗ Trung Quân**

- Facebook: https://www.facebook.com/dotrungquan.info/
- Website: https://dotrungquan.info/
