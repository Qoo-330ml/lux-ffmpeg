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
