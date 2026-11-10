# D3 实测:Secure Transport 能否连接 TLS 1.3-only 服务端

日期:2026-11-10。依据:计划 `lux-client/apple/docs/reviews/2026-11-10-lux-ffmpeg-full-adoption-plan.md` §8 D3 与 R3。

## 方法

- 服务端:本机 OpenSSL 4.1.0 `s_server`,自签证书(`lux/.build/tls-test/cert.pem`,不入库)。
  - 1.3-only:`-tls1_3 -accept 8443`;1.2 对照:`-tls1_2 -accept 8444`。
- 客户端:`lux/.build/tls-test/tls13_probe.c`,经 libavformat 的 `tls://` 协议(Secure Transport 后端,F2-1 构建)调用 `avio_open2`,`verify=0`。
- 对照:`openssl s_client -tls1_2` 连 1.3-only 服务端,确认服务端确实拒绝 TLS 1.2。

## 结果

| 组合 | 结果 |
| --- | --- |
| probe → 1.3-only 服务端 | **失败**:`Unable to negotiate TLS/SSL session: -9836`,`open failed: Input/output error` |
| `s_client -tls1_2` → 1.3-only 服务端 | 服务端返回 `tlsv1 alert protocol version`(确认 1.3-only 生效) |
| probe → 1.2 服务端(对照) | TLS 握手成功(`avio_read` 阻塞等待应用数据,在 8 秒超时内未返回,即握手已完成) |

## 结论

当前 Secure Transport 后端**不能连接只支持 TLS 1.3 的服务端**。它本身只支持到 TLS 1.2,这与 R3 的判断一致。
按计划 D3 的规则,「不能就加 OpenSSL」。加 OpenSSL 会引入一个新的依赖(Apache-2.0,与 LGPL-2.1+ 兼容),
并改变 `--enable-securetransport` 的 TLS 后端选择,**需要所有者确认后再实施**。在此之前,
MPVKit 能播而新底座连不上的回归风险仍然存在,需要在 P6 真机矩阵中单独覆盖。

## 未覆盖

- 只测了本机回环的 TLS 1.3-only 服务端;真实反代的证书链和 SNI 行为未测。
- 只测了 macOS arm64 切片的 Secure Transport;iOS 切片尚未做同样的探针。

## OpenSSL 后端复测(2026-11-10,D3 实施后)

D3 已把 TLS 后端从 Secure Transport 换成 OpenSSL 3.5.9(Apache-2.0,静态 `libssl.a`/`libcrypto.a`),
上面的历史记录保留不动。复测把探针移进了仓库(`lux/test/tls_probe.c`),并接进
`lux/test/run.sh` 第 9 段,不再依赖 `lux/.build/tls-test` 里的旧二进制。

### 方法

- 服务端:本构建的 OpenSSL 3.5.9 `s_server`(`lux/.build/deps/macos-arm64/install/bin/openssl`),
  自签证书由 `run.sh` 现场用同一个 openssl 生成(CN=localhost,只在本机回环使用)。
  - 1.3-only:`-tls1_3 -accept 127.0.0.1:8443 -www -naccept 2`;
  - 1.2-only:`-tls1_2 -accept 127.0.0.1:8444 -www -naccept 2`。
- 客户端:仓库内 `lux/test/tls_probe.c`,经 libavformat 的 `tls://` 协议(OpenSSL 后端)调用
  `avio_open2`,`verify=0`;打开后发 `GET / HTTP/1.0`,读到 EOF,并要求状态行是 `HTTP/1.0 200`。
  旧探针「握手后阻塞在 read 也算成功」的口径已废弃:读超时(socket 8s / 外层 `timeout 20`)
  一律判失败。
- 控制组:每个服务端先用**被禁用的版本**连一次(`s_client -tls1_2` 对 1.3-only、
  `s_client -tls1_3` 对 1.2-only),必须被拒绝;证明 `-tls1_X` 真的在生效,因此探针成功
  就只能是用了服务端允许的版本。

### 结果

| 组合 | 结果 |
| --- | --- |
| 控制组 `s_client -tls1_2` → 1.3-only(8443) | **失败**:服务端返回 `tlsv1 alert protocol version`(alert 70),符合预期 |
| probe → 1.3-only 服务端(8443) | **成功**:握手通过,读到 `HTTP/1.0 200 ok`,共 5608 字节 |
| 控制组 `s_client -tls1_3` → 1.2-only(8444) | **失败**:同样 `tlsv1 alert protocol version`(alert 70),符合预期 |
| probe → 1.2-only 服务端(8444) | **成功**:握手通过,读到 `HTTP/1.0 200 ok`,共 5532 字节 |

`lux/test/run.sh` 退出码 0,`RESULT: PASS`;两段 TLS 均 PASS。原 Secure Transport 的
`-9836`(1.3-only 失败)在 OpenSSL 后端不再复现。

### 仍未覆盖

- iOS 切片(iOS device / simulator)只验证了构建与静态库,没有在真机/模拟器上跑 TLS 探针;
  需要 P6 真机矩阵补上。
- 真实反代的证书链、SNI、ALPN 未测;本次只验证 TLS 版本协商与最小读取路径。
