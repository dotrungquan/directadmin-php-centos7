# DirectAdmin Legacy PHP Builder

Script build và tích hợp **PHP 8.2–8.5 từ source** trên **CentOS 7 + DirectAdmin 1.62.x**.

Mục tiêu chính là giúp máy chủ DirectAdmin cũ nâng cấp lên các nhánh PHP mới hơn, qua đó **hỗ trợ khắc phục các lỗ hổng bảo mật đã được vá trong những bản PHP cập nhật**.

Tham khảo: [PHP sắp phát hành bản vá hai lỗ hổng Critical CVSS 9.2](https://dotrungquan.info/php-sap-phat-hanh-ban-va-hai-lo-hong-critical-cvss-9-2/)

> [!CAUTION]
> ## LƯU Ý: BACKUP TRƯỚC KHI THỰC HIỆN
>
> Hãy tạo snapshot VPS hoặc bản backup có thể khôi phục. Quá trình build và tích hợp có thể làm website gián đoạn ngắn.

## Hỗ trợ

| Webserver | Handler |
|---|---|
| Apache | PHP-FPM |
| Nginx | PHP-FPM |
| `nginx_apache` | PHP-FPM |
| OpenLiteSpeed | LSPHP/LSAPI |
| LiteSpeed Enterprise | LSPHP/LSAPI |

Script tự nhận diện webserver trong DirectAdmin và chọn đúng chế độ build.

## Phiên bản

```text
PHP:     8.2.35, 8.3.36, 8.4.27, 8.5.12
Redis:   6.3.0
Imagick: 3.8.1
```

PHP được cài song song tại `/usr/local/phpXX`, không tự động thay PHP cho toàn bộ account.

## Chức năng chính

- Build PHP-FPM, LSPHP hoặc cả hai.
- Build Redis và Imagick theo đúng PHP ABI.
- Kiểm tra SHA-256 của source.
- Tích hợp PHP vào slot phụ của DirectAdmin.
- Tạo pool/socket PHP-FPM riêng cho từng user.
- Sinh cấu hình OpenLiteSpeed extProcessor/vhost.
- Transaction và rollback khi build hoặc integration thất bại.
- Xác minh runtime, service, socket, vhost và request HTTP thật.

## Cài đặt

```bash
mkdir -p /root/custom-da
cd /root/custom-da

curl -fsSL \
  -o da-php-build.sh \
  https://raw.githubusercontent.com/dotrungquan/directadmin-php-centos7/refs/heads/main/da-php-build.sh

chmod 750 da-php-build.sh
```

> Không dùng `curl ... | bash`. Hãy tải và kiểm tra script trước khi chạy.

## Cách sử dụng

### 1. Kiểm tra server

```bash
cd /root/custom-da
./da-php-build.sh check
./da-php-build.sh detect
```

### 2. Cài package và tải source

```bash
./da-php-build.sh setup
./da-php-build.sh fetch all
```

### 3. Build PHP

Build một phiên bản:

```bash
./da-php-build.sh php 8.4
```

Build toàn bộ:

```bash
./da-php-build.sh php all
```

Redis và Imagick được cài mặc định. Có thể tắt bằng:

```bash
INSTALL_EXTENSIONS=0 ./da-php-build.sh php 8.4
```

### 4. Tích hợp vào DirectAdmin

Cú pháp:

```bash
FORCE_SLOT=1 ./da-php-build.sh integrate PHP_VERSION SLOT USER DOMAIN
```

Ví dụ:

```bash
FORCE_SLOT=1 ./da-php-build.sh integrate \
  8.4 3 demo1 example.com
```

Script sẽ kiểm tra domain owner, slot, pool/socket hoặc LSPHP processor, vhost, service và request PHP thật trước khi commit.

> Hãy canary **một phiên bản và một domain** trước khi triển khai diện rộng.

### 5. Build lại extension

```bash
./da-php-build.sh extensions 8.4
```

### 6. Khôi phục transaction bị gián đoạn

```bash
./da-php-build.sh recover \
  /duong/dan/transaction/run.XXXXXX
```

Không tự xóa hoặc chỉnh sửa transaction chưa hoàn tất.

## Biến thường dùng

```bash
MODE=auto              # auto, fpm, lsphp hoặc both
JOBS=4                 # số luồng make
FORCE=1                # tiếp quản runtime không do script tạo
FORCE_SLOT=1           # cho phép thay release/mode của slot
RESTART=1              # restart runtime khi cấu hình hợp lệ
INSTALL_EXTENSIONS=0   # không cài Redis và Imagick
```

## Kiểm tra PHP 8.4

```bash
/usr/local/php84/bin/php -v
/usr/local/php84/bin/php -m | grep -E 'redis|imagick'
/usr/local/php84/bin/lsphp84 -v
```

PHP-FPM chưa có pool DirectAdmin sẽ được giữ `inactive/disabled`. Chạy `integrate` trước khi khởi động service.

## Tác giả

**Đỗ Trung Quân**

- Facebook: https://www.facebook.com/dotrungquan.info/
- Website: https://dotrungquan.info/
