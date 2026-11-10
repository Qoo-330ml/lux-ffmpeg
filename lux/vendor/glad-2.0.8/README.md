# glad 2.0.8 生成的 OpenGL / EGL 头文件(vendor)

- 用途:libplacebo 的 OpenGL 后端(`src/opengl/common.h` 包含 `<glad/gl.h>`、`<glad/egl.h>`)。
- 生成器:glad2 2.0.8(PyPI,MIT),由 `lux/build/install-glad.sh` 按
  `lux/config/requirements-glad.txt` 的 sha256(`pip install --require-hashes`)装到
  `lux/.build/deps/pydeps`。规范(Khronos,Apache-2.0)已内置在 glad2 包中,
  **生成过程不访问网络**;同一版本、同一参数的输出字节级一致(已验证两次,sha256 相同)。
- 扩展列表:`extensions.txt`,取自 libplacebo 7.360.1 的 `src/opengl/meson.build` 中 `gl_extensions`(35 项,与 libplacebo 7.360.1 相同)。
- 参数:`--reproducible --merge --api=gl:core,gles2,egl --extensions=<上表> c --header-only --mx`。
  未使用 `--loader`:加载函数由 libplacebo 通过 `get_proc_address` 提供。
- 许可:`LICENSE` 为 glad 源码 MIT 与 Khronos 规范 Apache-2.0 的原文。头文件中保留了 Khronos 版权声明。
- 重新生成:`./generate.sh`。修改头文件前先改生成器版本或参数并在本文件记录。
